import io
from datetime import timedelta

import numpy as np
import pytest
import soundfile as sf

from .test_flow import client
from ..database import AudioClipLog, utcnow
from ..routers import audio_clips


@pytest.fixture(autouse=True)
def isolated_audio(tmp_path, monkeypatch):
    monkeypatch.setattr(audio_clips,'FOLDER',tmp_path/'user_audio')


def wav():
    output = io.BytesIO()
    sf.write(output,np.zeros(16000,dtype=np.float32),16000,format='WAV')
    return output.getvalue()


def upload(client, extra=''):
    response = client.post('/audio-clips/upload?pet_id=dog-a&store_consent=true'+extra,
                           content=wav(),headers={'Content-Type':'audio/wav'})
    assert response.status_code == 201,response.text
    return response.json()


def test_explicit_consent_scope_review_and_original_deletion(client):
    assert client.post('/audio-clips/upload?pet_id=dog-a',content=wav()).status_code == 422
    item = upload(client)
    assert item['training_consent'] is False and item['verified'] is False
    prefix = '/audio-clips/'+item['id']
    assert client.get(prefix+'/audio?pet_id=other').status_code == 404
    assert client.get(prefix+'/audio?pet_id=dog-a').content == wav()
    player = client.get(prefix+'/player?pet_id=dog-a')
    assert player.status_code == 200 and '<audio controls' in player.text
    segment = client.get(prefix+'/player?pet_id=dog-a&start_s=0&end_s=1')
    assert segment.status_code == 200 and '#t=0,1' in segment.text
    assert '정확한 발성 시작' in segment.text
    assert client.get(prefix+'/player?pet_id=dog-a&start_s=0.5&end_s=1.5').status_code == 422
    assert client.get(prefix+'/player?pet_id=dog-a&start_s=0').status_code == 422
    assert client.get(prefix+'/player?pet_id=other').status_code == 404
    review = client.post(prefix+'/review',json={'pet_id':'dog-a','label':'uncertain','note':'확인 어려움'}).json()
    assert review['review']['source'] == 'guardian_opinion'
    assert review['verified'] is False
    assert client.post(prefix+'/consent',json={'pet_id':'dog-a','training_consent':True}).json()['training_consent'] is True
    assert client.post(prefix+'/delete-original?pet_id=other').status_code == 404
    deleted = client.post(prefix+'/delete-original?pet_id=dog-a').json()
    assert deleted['deleted'] is True and deleted['training_consent'] is False
    assert client.get(prefix+'/audio?pet_id=dog-a').status_code == 410
    assert client.get(prefix+'/player?pet_id=dog-a').status_code == 410
    assert client.post(prefix+'/consent',json={'pet_id':'dog-a','training_consent':True}).status_code == 410
    assert list(audio_clips.FOLDER.glob('*.wav')) == []


def test_expiry_removes_original_and_withdraws_training(client):
    item = upload(client,'&training_consent=true')
    with client.sessions() as db:
        row = db.get(AudioClipLog,item['id']); row.expires_at = utcnow()-timedelta(seconds=1)
        db.commit()
    assert client.get('/audio-clips?pet_id=dog-a').json()[0]['deleted'] is True
    assert list(audio_clips.FOLDER.glob('*.wav')) == []


def test_invalid_audio_and_session_mismatch_leave_no_orphan(client):
    assert client.post('/audio-clips/upload?pet_id=dog-a&store_consent=true',content=b'not wav').status_code == 422
    session = client.post('/outings',json={'pet_id':'dog-a','input_mode':'synthetic_demo'}).json()['id']
    assert client.post('/audio-clips/upload?pet_id=dog-a&store_consent=true&outing_id='+session,content=wav()).status_code == 422
    assert list(audio_clips.FOLDER.glob('*.wav')) == []
    assert client.get('/observations?pet_id=dog-a').json() == []


def test_uploaded_audio_attaches_to_outing_with_unknown_video(client):
    session = client.post('/outings',json={'pet_id':'dog-a','input_mode':'uploaded_audio'}).json()['id']
    item = upload(client,'&outing_id='+session)
    result = client.get('/outings/'+session+'/summary?pet_id=dog-a').json()
    assert result['counted_observation_ids'] == [item['observation_id']]
    assert result['unknown_seconds'] == result['sample_seconds'] == 1
    assert result['moments'][0]['audio_available'] is True
    client.post('/audio-clips/'+item['id']+'/review',json={'pet_id':'dog-a','label':'external_or_tv','note':'TV 소리로 확인'})
    from ..services.outings import facts_for_report
    from ..database import OutingLog
    with client.sessions() as db:
        report, facts = facts_for_report(db,db.get(OutingLog,session),'보호자 의견')
        assert len(facts) == 1 and facts[0]['kind'] == 'guardian_opinion'
        assert 'TV 소리로 확인' in facts[0]['text']
        assert facts[0]['observation_ids'] == [item['observation_id']]


def test_duplicate_upload_counted_once_but_both_opinions_remain(client):
    from ..services.outings import facts_for_report
    from ..database import OutingLog
    session = client.post('/outings', json={'pet_id': 'dog-a', 'input_mode': 'uploaded_audio'}).json()['id']
    first = upload(client, '&outing_id='+session)
    second = upload(client, '&outing_id='+session)
    for item in (first, second):
        client.post('/audio-clips/'+item['id']+'/review', json={'pet_id': 'dog-a', 'label': 'uncertain', 'note': '검증용 의견'})
    with client.sessions() as db:
        report, facts = facts_for_report(db, db.get(OutingLog, session), '보호자 의견')
        assert report['sample_seconds'] == 1
        assert report['counted_observation_ids'] == [first['observation_id']]
        assert report['skipped_overlap_ids'] == [second['observation_id']]
        assert len(facts) == 2
        assert [m['included_in_metrics'] for m in report['moments']] == [True, False]
    client.post('/audio-clips/'+first['id']+'/delete-original?pet_id=dog-a')
    assert client.get('/outings/'+session+'/summary?pet_id=dog-a').json()['sample_seconds'] == 1


def test_missing_audio_file_is_not_advertised_as_playable(client):
    session = client.post('/outings', json={'pet_id': 'dog-a', 'input_mode': 'uploaded_audio'}).json()['id']
    item = upload(client, '&outing_id='+session)
    with client.sessions() as db:
        audio_clips.path_for(db.get(AudioClipLog, item['id'])).unlink()
    moment = client.get('/outings/'+session+'/summary?pet_id=dog-a').json()['moments'][0]
    assert moment['audio_available'] is False and moment['audio_url'] is None
    assert '원본 파일이 없습니다' in moment['note']


def test_public_demo_provenance_cannot_become_user_training_data(client):
    url = '/audio-clips/upload?pet_id=demo-dog&store_consent=true&demo_source=ESC-50%2Fexample.wav'
    assert client.post(url+'&training_consent=true',content=wav()).status_code == 422
    result = client.post(url,content=wav())
    assert result.status_code == 201
    item = result.json()
    assert item['analysis']['input_scope'] == 'public_demo'
    assert 'ESC-50/example.wav' in item['source_note']
    assert '공개 자료 시연: ESC-50/example.wav' in client.get(
        '/audio-clips/'+item['id']+'/player?pet_id=demo-dog').text
    review = client.post('/audio-clips/'+item['id']+'/review',
                         json={'pet_id':'demo-dog','label':'uncertain','note':'example'}).json()
    assert review['review']['source'] == 'demo_operator_opinion'
    assert client.post('/audio-clips/'+item['id']+'/consent',
                       json={'pet_id':'demo-dog','training_consent':True}).status_code == 422
