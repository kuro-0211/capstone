"""Legacy approval/history flow adapted to observations and virtual device polling."""
import asyncio
import json
import uuid
from datetime import timedelta

from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from ..database import CareActionLog, CareSuggestionLog, ObservationLog, PetProfileLog, utcnow
from ..mcp_client import retrieve_records
from ..providers import RuleBasedProvider, get_provider
from ..schemas import CareSuggestionDraft
from ..settings import settings
from .observations import care_context
from . import retrieval
from .profiles import profile_out
from .frequency import compare_candidate_frequency
from .query_plan import plan_query


def suggestion_to_out(row):
    return {'id': row.id, 'pet_id': row.pet_id, 'observation_id': row.observation_id,
            'state': row.state, 'summary': row.summary, 'reasons': json.loads(row.reasons_json),
            'recommended_actions': json.loads(row.recommended_actions_json), 'music_style': row.music_style,
            'severity': row.severity, 'status': row.status, 'provider': row.provider,
            'context': json.loads(row.context_json), 'retrieval': json.loads(row.retrieval_json),
            'cited_observation_ids': json.loads(row.cited_ids_json), 'question': row.question,
            'created_at': row.created_at.isoformat() + 'Z'}


def action_to_out(row):
    return {'id': row.id, 'suggestion_id': row.suggestion_id, 'action_type': row.action_type,
            'command_id': row.command_id, 'status': row.status, 'request': json.loads(row.request_json),
            'result': json.loads(row.result_json) if row.result_json else None, 'error': row.error,
            'created_at': row.created_at.isoformat() + 'Z', 'updated_at': row.updated_at.isoformat() + 'Z'}


def evaluate(db, observation_id, question):
    observation = db.get(ObservationLog, observation_id)
    if observation is None:
        raise HTTPException(404, '관찰 기록을 찾을 수 없습니다.')
    context = care_context(observation)
    before = observation.observed_at.isoformat()
    query = question
    plan = plan_query(question, before)
    before = plan['before']
    if settings.retrieval_mode == 'mcp':
        try:
            evidence = asyncio.run(retrieve_records(observation.pet_id, before, query, plan['days'],
                                                   plan['start'], settings.semantic_enabled))
        except Exception:
            evidence = {'mode': 'mcp', 'status': 'failed', 'records': [], 'stats': {},
                        'care_history': [], 'tool_calls': [], 'error': 'MCP 기록 조회 실패'}
    else:
        search = retrieval.search_result(db, observation.pet_id, before, query, plan['days'],
                                         start=plan['start'], semantic=settings.semantic_enabled)
        evidence = {'mode': 'local', 'status': 'ok', **search,
                    'stats': retrieval.get_observation_stats(db, observation.pet_id, before, plan['days'], plan['start']),
                    'care_history': retrieval.get_care_history(db, observation.pet_id, before, start=plan['start']),
                    'tool_calls': []}
    evidence['query_plan'] = plan
    evidence['profile'] = profile_out(db.get(PetProfileLog, observation.pet_id))
    evidence['frequency_comparison'] = compare_candidate_frequency(context, evidence)
    provider = get_provider()
    provider_name = provider.name
    try:
        draft = CareSuggestionDraft.model_validate(provider.suggest(context, evidence, question))
        if not set(draft.cited_observation_ids).issubset({r['id'] for r in evidence['records']}):
            raise ValueError('provider cited a record outside retrieved evidence')
    except Exception as exc:
        provider_name = 'rule-fallback'
        response = getattr(exc, 'response', None)
        evidence['provider_failure'] = {'type': type(exc).__name__,
                                       'http_status': response.status_code if response is not None else None}
        draft = RuleBasedProvider().suggest(context, evidence, question)
    row = CareSuggestionLog(observation_id=observation.id, pet_id=observation.pet_id,
                            state=draft.state, summary=draft.summary,
                            reasons_json=json.dumps(draft.reasons, ensure_ascii=False),
                            recommended_actions_json=json.dumps(draft.recommended_actions),
                            music_style=draft.music_style, severity=draft.severity,
                            status='pending' if draft.recommended_actions else 'informational',
                            provider=provider_name, context_json=context.model_dump_json(),
                            retrieval_json=json.dumps(evidence, ensure_ascii=False),
                            cited_ids_json=json.dumps(draft.cited_observation_ids), question=question)
    db.add(row)
    db.commit()
    db.refresh(row)
    return suggestion_to_out(row)


def approve(db, suggestion_id, action_type):
    row = db.get(CareSuggestionLog, suggestion_id)
    if row is None:
        raise HTTPException(404, '케어 제안을 찾을 수 없습니다.')
    if action_type not in json.loads(row.recommended_actions_json):
        raise HTTPException(422, '제안에 허용되지 않은 액션입니다.')
    changed = db.execute(update(CareSuggestionLog).where(
        CareSuggestionLog.id == suggestion_id, CareSuggestionLog.status == 'pending'
    ).values(status='approved')).rowcount
    if not changed:
        db.rollback()
        raise HTTPException(409, '이미 승인 또는 거절된 제안입니다.')
    action = CareActionLog(suggestion_id=suggestion_id, command_id=str(uuid.uuid4()),
                          request_json=json.dumps({'style': row.music_style, 'mode': 'simulated'}))
    db.add(action)
    try:
        db.commit()  # Persist before the virtual agent can receive a command.
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, '이미 요청된 액션입니다.')
    db.refresh(action)
    return action_to_out(action)


def dismiss(db, suggestion_id):
    row = db.get(CareSuggestionLog, suggestion_id)
    if row is None:
        raise HTTPException(404, '케어 제안을 찾을 수 없습니다.')
    changed = db.execute(update(CareSuggestionLog).where(
        CareSuggestionLog.id == suggestion_id, CareSuggestionLog.status == 'pending'
    ).values(status='dismissed')).rowcount
    if not changed:
        db.rollback()
        raise HTTPException(409, '대기 중인 제안만 거절할 수 있습니다.')
    db.commit()
    db.refresh(row)
    return suggestion_to_out(row)


def expire_stale_actions(db):
    deadline = utcnow() - timedelta(seconds=settings.action_timeout_seconds)
    db.execute(update(CareActionLog).where(
        CareActionLog.status.in_(['requested', 'acknowledged']), CareActionLog.created_at < deadline
    ).values(status='timed_out', error='가상 장치 완료 응답 시간 초과', updated_at=utcnow()))
    db.commit()


def acknowledge(db, command_id, status, detail):
    expire_stale_actions(db)
    row = db.scalars(select(CareActionLog).where(CareActionLog.command_id == command_id)).first()
    if row is None:
        raise HTTPException(404, '명령을 찾을 수 없습니다.')
    if row.status == status:
        return action_to_out(row)
    predecessors = ['requested'] if status == 'acknowledged' else ['acknowledged']
    changed = db.execute(update(CareActionLog).where(
        CareActionLog.id == row.id, CareActionLog.status.in_(predecessors)
    ).values(status=status, updated_at=utcnow(), error=detail if status == 'failed' else None,
             result_json=json.dumps({'simulated': True, 'detail': detail}, ensure_ascii=False))).rowcount
    if not changed:
        db.rollback()
        raise HTTPException(409, '현재 상태에서 해당 응답으로 변경할 수 없습니다.')
    db.commit()
    db.refresh(row)
    return action_to_out(row)
