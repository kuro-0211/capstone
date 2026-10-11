# Genesis UI와 공개 음원 시연 설명 영상

기준일: 2026-10-11. 로컬 영상: `artifacts/presentation_20261011/petmind_genesis_browser_walkthrough.mp4`. **실제 로컬 브라우저 화면 캡처를 편집한 설명 영상이며, 연속 클릭 화면 녹화는 아니다.** 약 2분 57초, 1920×1080 H.264/AAC다. 영상 원본과 합성 음성은 Git에서 제외한 `artifacts/`에 남긴다. GitHub에서 영상 파일을 직접 열 수는 없으며, 같은 PC에서 경로를 열거나 아래 명령으로 재생성한다.

| 구간 | 내용 | 화면·수치의 근거 |
|---|---|---|
| 00:00–00:18 | 기존 다크 UI와 Genesis 적용 UI 비교 | [화면 비교](37_Genesis_UI_적용_비교.md) |
| 00:18–00:36 | 실제 브라우저 첫 화면·외출 흐름 | `verified_browser_dashboard_top.png` |
| 00:36–01:02 | 공개 Dog 음원 감지, 원본 5초 재생, 업로드 후 입력 초기화 | `verified_browser_second_upload_reset.png`, ESC-50 `5-203128-A-0.wav` |
| 01:02–01:25 | 동일 모델이 놓친 공개 Dog 사례 | `verified_browser_audio_review.png`, ESC-50 `1-100032-A-0.wav` |
| 01:25–01:47 | 귀가 요약 수치·시연 출처·관찰 근거 | `verified_browser_summary.png` |
| 01:47–02:09 | 시간 질문에 표본·판단 불가·출처 근거로 답하는 화면 | `verified_browser_duration_question.png` |
| 02:09–02:33 | 기존 LSTM과 증강·MIL 후보의 동일 평가 자료 F1 | [`audio_lstm_three_way.json`](evidence/audio_lstm_three_way.json) |
| 02:33–02:57 | 실제 가정 음향·사람 정답·독립 평가의 남은 과제 | 현재 구현·검증 한계 |

ESC-50 음원은 공식 평가 분할의 공개 자료이며, 영상에는 실제 보호자 기록이나 반려견 감정·질환 판정이 없다. `5-203128-A-0.wav`의 원본 해시를 확인해 삽입했다. 화면의 `93.9/100`과 `44.5/100`은 특정 5초 입력의 실험 점수이고 정확도·확률이 아니다. FSD50K 평가 F1은 기존 0.436, 증강 후보 0.430으로 낮아 운영 체크포인트를 유지했다. 후보의 검증 점수 상승을 실제 현장 정확도 향상으로 소개하지 않는다.

재생성은 저장소 루트에서 아래 명령을 실행한다. 세 공개 음원은 별도 준비 명령이 검증해 Git 제외 `artifacts/datasets/esc50_demo/`에 둔다. 생성 스크립트는 현재 저장된 브라우저 스크린샷, Windows 한국어 음성 합성, 공개 음원, 고정 평가 JSON을 사용한다.

```powershell
python -m scripts.prepare_demo_audio
python -m scripts.build_genesis_browser_walkthrough
```

실행 후 비디오의 시작·55초·112초·165초 프레임이 디코딩되는 것을 확인했다. AAC에서 55~60초의 개 소리 구간을 디코딩해 원본과 비교한 상관계수는 약 0.9997이었다. 합성 내레이션 파일 8개와 공개 음원은 재생성 결과에 포함된다. 영상은 발표의 준비된 설명 자료로 쓰고, 실제 클릭 흐름은 로컬 앱에서 별도 시연한다. 현재 연속 클릭 녹화 파일은 확보하지 않았다.
