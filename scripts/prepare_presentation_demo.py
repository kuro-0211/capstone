"""Populate the isolated localhost presentation DB with clearly marked public audio.

Requires the API to be started with a disposable PETMIND_DATABASE_URL under artifacts/.
Only ESC-50 test clips and public-dataset provenance are sent to localhost.
"""
import hashlib
import json
from pathlib import Path

import requests

ROOT = Path('artifacts/datasets/esc50/audio')
BASE = 'http://127.0.0.1:8013'
PET = 'demo-dog'
EVIDENCE = Path('docs/evidence/presentation_demo_api.json')


def call(method, path, **kwargs):
    response = requests.request(method, BASE+path, timeout=90, **kwargs)
    response.raise_for_status()
    return response.json()


def review(clip, label, note):
    return call('POST', f'/audio-clips/{clip["id"]}/review',
                json={'pet_id': PET, 'label': label, 'note': note})


def upload(outing, filename):
    content = (ROOT/filename).read_bytes()
    result = call('POST', '/audio-clips/upload', params={'pet_id': PET,
        'store_consent': 'true', 'training_consent': 'false', 'outing_id': outing,
        'demo_source': f'ESC-50 / {filename}'}, data=content,
        headers={'Content-Type': 'audio/wav'})
    return result, hashlib.sha256(content).hexdigest()


def main():
    outings = call('GET', '/outings', params={'pet_id': PET})
    if len(outings) not in (1, 2) or any(o['status'] != 'ended' for o in outings):
        raise RuntimeError('Expected one or two completed outings in the isolated DB')
    clips = call('GET', '/audio-clips', params={'pet_id': PET})
    by_source = {c['analysis'].get('demo_source'): c for c in clips}
    if 'ESC-50 / 5-203128-A-0.wav' not in by_source:
        raise RuntimeError('Expected the browser-uploaded public Dog example')
    first = review(by_source['ESC-50 / 5-203128-A-0.wav'], 'uncertain',
                   '공개 ESC-50 Dog 라벨 음원입니다. 시연 담당자의 메모이며 실제 보호자 확인은 아닙니다.')
    if len(outings) == 1:
        session = call('POST', '/outings', json={'pet_id': PET, 'input_mode': 'uploaded_audio',
                                                'title': '공개 음원 검증 시연 2'})
        missed, missed_hash = upload(session['id'], '5-208030-A-0.wav')
        missed = review(missed, 'uncertain',
                        'ESC-50 Dog 라벨인데 기존 LSTM은 놓쳤습니다. 공개 자료 검증 사례입니다.')
        rain, rain_hash = upload(session['id'], '5-181766-A-10.wav')
        rain = review(rain, 'other', 'ESC-50 rain 라벨의 외부 환경음입니다. TV 소리로 확인한 기록이 아닙니다.')
        call('POST', f'/outings/{session["id"]}/end', params={'pet_id': PET}, json={})
    else:
        session = outings[0]
        missed = by_source['ESC-50 / 5-208030-A-0.wav']
        rain = by_source['ESC-50 / 5-181766-A-10.wav']
        missed_hash = hashlib.sha256((ROOT/'5-208030-A-0.wav').read_bytes()).hexdigest()
        rain_hash = hashlib.sha256((ROOT/'5-181766-A-10.wav').read_bytes()).hexdigest()
    summary = call('GET', f'/outings/{session["id"]}/summary', params={'pet_id': PET})
    explanations = {}
    for name, question in [('sounds', '무슨 소리가 있었어?'),
                           ('comparison', '지난번과 달라?'),
                           ('tv', '보호자가 TV라고 확인한 것은?')]:
        explanations[name] = call('POST', f'/outings/{session["id"]}/explain',
                                  json={'pet_id': PET, 'question': question})
    result = {'source': 'ESC-50 official test split; isolated local presentation database',
              'pet_id': PET, 'outing_ids': [outings[-1]['id'], session['id']],
              'input_sha256': {'dog_detected': hashlib.sha256((ROOT/'5-203128-A-0.wav').read_bytes()).hexdigest(),
                               'dog_missed': missed_hash, 'rain': rain_hash},
              'review_sources': [first['review']['source'], missed['review']['source'], rain['review']['source']],
              'summary': {'sample_seconds': summary['sample_seconds'],
                          'bark_candidate_count': summary['bark_candidate_count'],
                          'unknown_seconds': summary['unknown_seconds']},
              'model_windows': {k: v['analysis'].get('audio_lstm', {}).get('windows', [])
                                for k, v in [('dog_missed', missed), ('rain', rain)]},
              'questions': {k: {'question': q['question'], 'provider': q['provider'],
                                'retrieval_mode': q['retrieval_mode'], 'answer': q['answer'],
                                'claims': q['claims']} for k, q in explanations.items()},
              'scope': 'Public dataset simulation, not longitudinal pet history or user-ground-truth accuracy'}
    EVIDENCE.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'summary': result['summary'],
                      'questions': {k: v['answer'] for k, v in result['questions'].items()}},
                     ensure_ascii=False))


if __name__ == '__main__':
    main()
