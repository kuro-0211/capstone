import json

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError

from pet_monitor.context import MOTION_LABELS_KO
from ..database import ObservationLog
from ..schemas import ObservationIn, ObservationOut, PetContext


def to_out(row):
    return ObservationOut(id=row.id, pet_id=row.pet_id, session_id=row.session_id,
                          observed_at=row.observed_at, source=row.source,
                          context=json.loads(row.context_json), summary=row.summary)


def save(db, data: ObservationIn):
    b, m = data.context.bark, data.context.motion
    summary = (f'{data.context.window_s:g}초 관찰: 짖음 후보 {b.count}회, '
               f'주된 궤적 {MOTION_LABELS_KO[m.dominant]}.')
    row = ObservationLog(pet_id=data.pet_id, session_id=data.session_id,
                         observed_at=data.observed_at, source=data.source,
                         context_json=data.context.model_dump_json(), summary=summary)
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, '같은 세션·시각의 관찰이 이미 저장되어 있습니다.')
    db.refresh(row)
    return to_out(row)


def care_context(row):
    data = json.loads(row.context_json)
    motion, bark = data['motion'], data['bark']
    return PetContext(observed_behavior=motion['dominant'],
                      behavior_duration_seconds=motion['seconds_by_label'].get(motion['dominant'], 0),
                      bark_detected=bark['count'] > 0, bark_count=bark['count'],
                      bark_volume=bark['peak_db'], window_s=data['window_s'],
                      motion_model=data.get('motion_model', 'rule'), input_note=data.get('input_note', ''),
                      lstm_metadata=data.get('lstm_metadata', {}))
