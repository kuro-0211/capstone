from dataclasses import replace
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from petmind.backend import main, mcp_client
from petmind.backend.database import Base, CareActionLog, get_db
from petmind.backend.services import care


@pytest.fixture
def client(tmp_path, monkeypatch):
    url = f'sqlite:///{tmp_path / "test.db"}'
    engine = create_engine(url, connect_args={'check_same_thread': False})
    Base.metadata.create_all(engine)
    sessions = sessionmaker(engine)
    def db_override():
        with sessions() as db:
            yield db
    main.app.dependency_overrides[get_db] = db_override
    monkeypatch.setattr(main, 'init_db', lambda: None)
    monkeypatch.setattr(main, 'cleanup_once', lambda: None)
    monkeypatch.setattr(care, 'settings', replace(care.settings, provider='rule', retrieval_mode='local', semantic_enabled=False))
    monkeypatch.setattr(mcp_client, 'settings', replace(mcp_client.settings, database_url=url))
    # Provider selection is independent from the retrieval mode.
    monkeypatch.setattr(care, 'get_provider', lambda: care.RuleBasedProvider())
    with TestClient(main.app) as http:
        http.sessions = sessions
        yield http
    main.app.dependency_overrides.clear()
    engine.dispose()


def observe(client, pet='dog-a', scenario='anxious', when=None):
    payload = {'pet_id': pet, 'session_id': f'{pet}-{when or datetime.now(timezone.utc).isoformat()}',
               'observed_at': when or datetime.now(timezone.utc).isoformat(), 'source': 'synthetic_demo',
               'context': main.analyze_demo(scenario)}
    response = client.post('/observations', json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def evaluate(client, observation):
    response = client.post('/care/evaluate', json={'observation_id': observation['id']})
    assert response.status_code == 200, response.text
    return response.json()


def test_health_reports_audio_checkpoint_presence_without_claiming_validity(client, tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'ROOT', tmp_path)
    monkeypatch.setattr(main, 'SessionLocal', client.sessions)
    key = 'audio_lstm_checkpoint_present'
    assert client.get('/health').json()['components'][key] is False
    checkpoint = tmp_path/'artifacts/audio_lstm/esc50_lstm.pt'
    checkpoint.parent.mkdir(parents=True)
    checkpoint.write_bytes(b'not a valid model')
    assert client.get('/health').json()['components'][key] is True


def test_observe_evaluate_approve_receive_complete_and_persist(client):
    observation = observe(client)
    suggestion = evaluate(client, observation)
    assert suggestion['status'] == 'pending'
    assert client.get('/care/actions/pending').json() == []
    action = client.post(f'/care/{suggestion["id"]}/approve', json={'action_type': 'music'}).json()
    assert action['status'] == 'requested'
    assert client.post(f'/care/{suggestion["id"]}/approve', json={'action_type': 'music'}).status_code == 409
    path = f'/care/actions/{action["command_id"]}/ack'
    assert client.post(path, json={'status': 'completed'}).status_code == 409
    assert client.post(path, json={'status': 'acknowledged'}).json()['status'] == 'acknowledged'
    assert client.post(path, json={'status': 'completed'}).json()['status'] == 'completed'
    assert client.post(path, json={'status': 'acknowledged'}).status_code == 409
    assert client.post(path, json={'status': 'completed'}).status_code == 200
    with client.sessions() as db:
        assert db.scalars(select(CareActionLog)).one().status == 'completed'
    metrics = client.get('/metrics?pet_id=dog-a').json()
    assert metrics['observations'] == 1 and metrics['actions_completed'] == 1
    assert len(client.get('/timeline?pet_id=dog-a').json()) == 3


def test_search_is_pet_scoped_temporal_and_bounded(client):
    now = datetime.now(timezone.utc)
    past = observe(client, when=(now - timedelta(days=1)).isoformat())
    observe(client, pet='other-dog', when=(now - timedelta(days=1)).isoformat())
    observe(client, when=(now + timedelta(days=1)).isoformat())
    current = observe(client, when=now.isoformat())
    result = evaluate(client, current)
    assert [r['id'] for r in result['retrieval']['records']] == [past['id']]
    assert result['retrieval']['stats']['sample_count'] == 1
    assert result['cited_observation_ids'] == [past['id']]
    assert len(client.get('/observations?pet_id=other-dog').json()) == 1


def test_real_mcp_subprocess_round_trip(client, monkeypatch):
    monkeypatch.setattr(care, 'settings', replace(care.settings, retrieval_mode='mcp'))
    now = datetime.now(timezone.utc)
    past = observe(client, when=(now-timedelta(days=1)).isoformat())
    result = evaluate(client, observe(client, when=now.isoformat()))
    evidence = result['retrieval']
    assert evidence['status'] == 'ok', evidence
    assert evidence['mode'] == 'mcp'
    assert [r['id'] for r in evidence['records']] == [past['id']]
    assert len(evidence['tool_calls']) == 3


def test_timeout_is_terminal(client):
    suggestion = evaluate(client, observe(client))
    action = client.post(f'/care/{suggestion["id"]}/approve', json={}).json()
    with client.sessions() as db:
        row = db.scalars(select(CareActionLog)).one()
        row.created_at = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(minutes=5)
        db.commit()
    assert client.get('/care/actions/pending').json() == []
    assert client.post(f'/care/actions/{action["command_id"]}/ack', json={'status': 'acknowledged'}).status_code == 409
    assert client.get('/care/actions/recent?pet_id=dog-a').json()[0]['status'] == 'timed_out'


def test_calm_unknown_empty_history_and_dismiss(client):
    result = evaluate(client, observe(client, scenario='calm'))
    assert result['recommended_actions'] == []
    assert result['retrieval']['status'] == 'ok' and result['retrieval']['records'] == []
    assert client.post(f'/care/{result["id"]}/approve', json={}).status_code == 422
    other = evaluate(client, observe(client, pet='new-dog'))
    assert client.post(f'/care/{other["id"]}/dismiss').json()['status'] == 'dismissed'
    assert client.post(f'/care/{other["id"]}/approve', json={}).status_code == 409


def test_missing_observation_and_invalid_input(client):
    assert client.post('/care/evaluate', json={'observation_id': 9999}).status_code == 404
    data = observe(client)
    data.pop('id'); data.pop('summary')
    assert data['observed_at'].endswith('Z')
    assert client.post('/observations', json=data).status_code == 409
    data['observed_at'] = '2026-10-11T12:00:00'
    assert client.post('/observations', json=data).status_code == 422
    assert client.get('/observations?pet_id=dog-a&limit=0').status_code == 422


def test_invalid_llm_citation_falls_back(client, monkeypatch):
    class InvalidProvider:
        name = 'gemini:test'
        def suggest(self, context, evidence, question):
            draft = care.RuleBasedProvider().suggest(context, evidence, question)
            draft.cited_observation_ids = [987654]
            return draft
    monkeypatch.setattr(care, 'get_provider', InvalidProvider)
    result = evaluate(client, observe(client))
    assert result['provider'] == 'rule-fallback'
    assert result['cited_observation_ids'] == []


def test_mcp_failure_is_not_empty_success(client, monkeypatch):
    async def fail(*args):
        raise RuntimeError('connection failed')
    monkeypatch.setattr(care, 'settings', replace(care.settings, retrieval_mode='mcp'))
    monkeypatch.setattr(care, 'retrieve_records', fail)
    result = evaluate(client, observe(client))
    assert result['retrieval']['status'] == 'failed'
