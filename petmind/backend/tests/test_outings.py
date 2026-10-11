import hashlib
import json
from dataclasses import replace
from datetime import datetime, timedelta, timezone

import pytest

from .test_flow import client
from ..database import ObservationLog, ObservationMedia, OutingLog
from ..services import outings
from ..routers import outings as routes


@pytest.fixture(autouse=True)
def local_explanation(monkeypatch):
    monkeypatch.setattr(outings, 'settings', replace(outings.settings, provider='rule', retrieval_mode='local'))


def start(client, pet='dog-a', mode='synthetic_demo'):
    response = client.post('/outings', json={'pet_id': pet, 'input_mode': mode})
    assert response.status_code == 201, response.text
    return response.json()['id']


def observe(client, outing, pet='dog-a'):
    response = client.post('/demo/observe', json={'pet_id': pet, 'scenario': 'anxious', 'outing_id': outing})
    assert response.status_code == 201, response.text
    return response.json()


def test_lifecycle_legacy_and_isolation(client):
    oid = start(client)
    assert client.post('/outings', json={'pet_id': 'dog-a'}).status_code == 409
    observation = observe(client, oid)
    assert observation['outing_id'] == oid
    assert client.get('/observations?pet_id=dog-a').json()[0]['outing_id'] == oid
    assert client.get(f'/outings/{oid}/summary?pet_id=other').status_code == 404
    assert client.post(f'/outings/{oid}/end?pet_id=other').status_code == 404
    assert client.post('/demo/observe', json={'pet_id': 'other', 'outing_id': oid}).status_code == 404
    report = client.get(f'/outings/{oid}/summary?pet_id=dog-a').json()
    assert report['sample_seconds'] > 0
    assert sum(report['seconds_by_label'].values()) == pytest.approx(report['sample_seconds'])
    assert report['moments'][0]['media_available'] is False
    assert report['unobserved_seconds'] is None
    first = client.post(f'/outings/{oid}/end?pet_id=dog-a').json()
    assert client.post(f'/outings/{oid}/end?pet_id=dog-a').json() == first
    assert client.post('/demo/observe', json={'pet_id': 'dog-a', 'outing_id': oid}).status_code == 409
    assert start(client) != oid
    assert client.post('/demo/observe', json={'pet_id': 'legacy'}).json()['outing_id'] is None


def test_source_time_and_empty_evidence(client):
    oid = start(client, mode='prepared_video')
    assert client.post('/demo/observe', json={'pet_id': 'dog-a', 'outing_id': oid}).status_code == 422
    result = client.post(f'/outings/{oid}/explain', json={'pet_id': 'dog-a'}).json()
    assert result['claims'] == [] and result['report']['sample_seconds'] == 0
    old = observe(client, None, pet='legacy')
    oid2 = start(client, pet='legacy')
    old.pop('id'); old.pop('summary'); old['outing_id'] = oid2
    assert client.post('/observations', json=old).status_code == 422


def test_duplicate_video_unknown_and_media_integrity(client, tmp_path, monkeypatch):
    monkeypatch.setattr(routes, 'MEDIA_ROOT', tmp_path)
    oid = start(client)
    one, two = observe(client, oid), observe(client, oid)
    content = b'0123456789'
    (tmp_path / 'sample.mp4').write_bytes(content)
    with client.sessions() as db:
        for item in (one, two):
            row = db.get(ObservationLog, item['id'])
            context = json.loads(row.context_json)
            context['motion']['seconds_by_label'] = {'moving': 3}
            row.context_json = json.dumps(context)
            db.add(ObservationMedia(observation_id=row.id, filename='sample.mp4',
                sha256=hashlib.sha256(content).hexdigest(), start_s=0, end_s=context['window_s'],
                source_json=json.dumps({'attribution': '<script>bad()</script>', 'license': 'test'})))
        db.commit()
    report = client.get(f'/outings/{oid}/summary?pet_id=dog-a').json()
    assert report['counted_observation_ids'] == [one['id']]
    assert report['skipped_overlap_ids'] == [two['id']]
    assert report['unknown_seconds'] == report['sample_seconds'] - 3
    path = f"/outings/observations/{one['id']}"
    assert client.get(path+'/clip?pet_id=dog-a').status_code == 200
    assert '<script>bad()' not in client.get(path+'/clip?pet_id=dog-a').text
    assert client.get(path+'/video?pet_id=other').status_code == 404
    part = client.get(path+'/video?pet_id=dog-a', headers={'Range': 'bytes=2-5'})
    assert part.status_code == 206 and part.content == b'2345'
    (tmp_path / 'sample.mp4').write_bytes(b'changed')
    assert client.get(path+'/video?pet_id=dog-a').status_code == 409
    (tmp_path / 'sample.mp4').unlink()
    assert client.get(path+'/clip?pet_id=dog-a').status_code == 404
    missing = client.get(f'/outings/{oid}/summary?pet_id=dog-a').json()['moments'][0]
    assert missing['media_available'] is False and missing['clip_url'] is None
    assert '원본 파일이 없습니다' in missing['note']


def test_kst_day_and_live_boundary(client):
    one, two = observe(client, None), observe(client, None)
    with client.sessions() as db:
        a, b = db.get(ObservationLog, one['id']), db.get(ObservationLog, two['id'])
        a.observed_at = datetime(2026, 10, 10, 15, 0, 10)  # crosses KST midnight
        b.observed_at = datetime(2026, 10, 10, 15, 2)
        a.source = b.source = 'live'
        db.commit()
    report = client.get('/outings/day?pet_id=dog-a&day=2026-10-11').json()
    assert report['timezone'] == 'Asia/Seoul'
    assert report['excluded_day_boundary_ids'] == [one['id']]
    assert report['counted_observation_ids'] == [two['id']]
    assert client.get('/outings/day?pet_id=dog-a&day=2026-10-10').json()['sample_seconds'] == 0
    explanation = client.post('/outings/day/explain?day=2026-10-11', json={
        'pet_id': 'dog-a', 'question': '오늘 요약과 판단 불가 시간'}).json()
    assert explanation['report']['counted_observation_ids'] == [two['id']]
    assert explanation['retrieval_mode'] == 'local-day'
    assert all(c['observation_ids'] == [two['id']] for c in explanation['claims'])
    assert str(report['bark_candidate_count']) in next(c['text'] for c in explanation['claims'] if c['kind'] == 'bark')
    assert client.post('/outings/day/explain?day=2026-10-11', json={
        'pet_id': 'other', 'question': '오늘 요약'}).json()['claims'] == []


def test_comparison_scoped_and_no_unsupported_question(client):
    previous = start(client)
    old = observe(client, previous)
    client.post(f'/outings/{previous}/end?pet_id=dog-a')
    other = start(client, pet='other')
    distractor = observe(client, other, pet='other')
    current = start(client)
    now = observe(client, current)
    result = client.post(f'/outings/{current}/explain', json={'pet_id': 'dog-a', 'question': '지난 외출과 비교'}).json()
    comparison = next(c for c in result['claims'] if c['id'] == 'comparison.bark_rate')
    assert set(comparison['observation_ids']) == {old['id'], now['id']}
    assert distractor['id'] not in comparison['observation_ids']
    assert client.post(f'/outings/{current}/explain', json={'pet_id': 'dog-a', 'question': '내일 날씨는?'}).json()['claims'] == []


def test_mcp_outing_roundtrip_and_invalid_generated_fact(client, monkeypatch):
    oid = start(client)
    observe(client, oid)
    monkeypatch.setattr(outings, 'settings', replace(outings.settings, retrieval_mode='mcp'))
    result = client.post(f'/outings/{oid}/explain', json={'pet_id': 'dog-a'}).json()
    assert result['retrieval_mode'] == 'mcp', result
    assert result['claims'] and result['retrieval_failure'] is None
    monkeypatch.setattr(outings, 'settings', replace(outings.settings, provider='gemini', gemini_api_key='test', retrieval_mode='local'))
    class Response:
        def raise_for_status(self): pass
        def json(self):
            return {'candidates': [{'content': {'parts': [{'text': '{"fact_ids":["invented"]}'}]}}]}
    monkeypatch.setattr('requests.post', lambda *a, **k: Response())
    result = client.post(f'/outings/{oid}/explain', json={'pet_id': 'dog-a'}).json()
    assert result['provider'] == 'grounded-template-fallback'
    assert result['failure'] == 'ValueError'
    assert all(c['id'] in result['retrieved_fact_ids'] for c in result['claims'])
