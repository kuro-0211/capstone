from scripts.prepare_presentation_demo import dog_review_note


def test_demo_review_describes_actual_model_outcome():
    missed = {'analysis': {'audio_lstm': {'dog_score': 0.04, 'threshold': 0.9}}}
    detected = {'analysis': {'audio_lstm': {'dog_score': 0.94, 'threshold': 0.9}}}
    unavailable = {'analysis': {}}

    assert '기준값에 못 미쳤습니다' in dog_review_note(missed)
    assert '기준값 이상입니다' in dog_review_note(detected)
    assert '놓침 여부는 확인할 수 없습니다' in dog_review_note(unavailable)
