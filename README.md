# PetMind — 반려견 관찰·개별 기록 기반 케어 시제품

영상 좌표와 음성 후보 이벤트를 관찰 기록으로 저장하고, 같은 반려견의 과거 기록을 MCP로 검색하여 케어 제안에 활용한다. 보호자가 승인한 제안만 가상 음악 장치로 전달한다. 급식기는 범위에서 제외한다.

이 저장소의 루트가 현재 개발 기준이다. 초기 분석 코드는 [wuerphe39/capstone_really](https://github.com/wuerphe39/capstone_really), 이 저장소의 이전 시제품은 [`legacy/`](legacy/README.md)에 보관했다. 이전 시제품의 FastAPI·SQLite·Flutter 제안·승인·이력 구조와 Gemini 제공자를 선별 재사용했다.

## 현재 확인한 결과

- 모델 산출물이 있는 개발 환경에서 Python 테스트 **66개 통과**. 모델을 포함하지 않은 새 저장소 복제본에서는 **65개 통과·1개 건너뜀**(`scripts.train_lstm` 실행 전)으로 확인했다.
- Flutter 분석 오류 없음, 화면 흐름 테스트 **2개 통과**, 웹 빌드 성공.
- 실제 HTTP에서 합성 입력 3종을 재시작 없이 처리. MCP 도구 3개씩 호출, 음악 제안 2건 승인·가상 실행 완료.
- 공개 WAV·공개 이미지 재생 영상에서도 관찰→저장→검색→제안→승인→가상 실행 완료.
- 초기 LSTM 학습 완료. 합성 테스트 400개에서 100%; 실제 반려견 행동 정확도는 미검증.
- 공개 음원 20개 파일럿: 개 소리 5개 모두 후보 감지, 비개 소리 15개 중 3개 오탐. 음성은 **짖음 후보**로 표시한다.
- 실제 Gemini 기반 RAG와 근거 인용을 확인했다. 합성 시나리오 3종과 공개 입력의 HTTP 흐름도 성공했다. 규칙 폴백을 Gemini 성공으로 계산하지 않는다.
- 반려견 프로필·보호자 피드백·타임라인·처리 수치·케어 전후 비교·평소 패턴의 표본 부족 처리를 구현했다. 실제 장기 기록은 아직 없다.
- 발표용 [Flutter 렌더링 캡처](docs/evidence/flutter_dashboard_render.png). 실제 브라우저 클릭 증거와 구분한다. 캡처에 포함된 DAVIS 개 이미지의 출처·이용 조건은 [공개 입력 기록](docs/evidence/public_inputs.json)을 따른다.
- 실제 Pi의 바탕화면 `PetMind_Test` 폴더에서 명령 완료·실패·중복·늦은 응답·무응답 시간초과를 검증했다. 물리 음악·센서는 실행하지 않았다. [Pi 테스트 기록](docs/20_Pi_바탕화면_왕복테스트.md).

## 실행 환경

Windows / Python 3.12 / Flutter. 새 실행 환경에서는 저장소 루트에서 다음을 실행한다.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-vision.txt
```

영상·학습 없이 분석 API만 확인하려면 `requirements-core.txt`를 사용한다. `requirements-lock.txt`는 이번 Windows 환경에서 확인한 전체 패키지 버전이다. 영상 관련 모듈은 선택 기능 실행 시 로딩한다.

## 모델·공개 입력 준비

```powershell
.\.venv\Scripts\python.exe -m scripts.train_lstm
.\.venv\Scripts\python.exe -m scripts.prepare_media
.\.venv\Scripts\python.exe -m scripts.evaluate_audio
.\.venv\Scripts\python.exe -m scripts.prepare_davis
.\.venv\Scripts\python.exe -m scripts.evaluate_video
```

DAVIS 공식 이미지 자료는 약 833MB이다. 모델·입력·평가 산출물은 `artifacts/`에 저장하며 Git에서 제외한다. 다운로드 출처·라이선스·파일 해시는 `docs/evidence/public_inputs.json`과 생성된 manifest를 참고한다.

DAVIS 이미지 시퀀스는 **5fps 재생용 영상**으로 구성했다. 원본 녹화 FPS·움직임 속도는 검증되지 않았다. 공개 영상과 별도 WAV를 합친 입력은 합성 시연이며 실제 동시 녹화가 아니다. 카메라 이동은 보정하지 않는다.

## 서버·화면·가상 장치

각 터미널은 저장소 루트에서 시작한다.

```powershell
# 터미널 1
.\.venv\Scripts\python.exe -m uvicorn petmind.backend.main:app --host 127.0.0.1 --port 8010

# 터미널 2
.\.venv\Scripts\python.exe -m petmind.device_agent

# 터미널 3
cd petmind_app
flutter pub get
flutter run -d chrome --web-port 8021
```

API 문서: `http://127.0.0.1:8010/docs`. 앱의 기본 API 주소는 `http://localhost:8010`이다. 필요하면 Flutter 실행에 `--dart-define=PETMIND_API_BASE=http://127.0.0.1:8010`을 추가한다.

웹 빌드를 사용할 수도 있다.

```powershell
cd petmind_app
flutter build web --release --no-web-resources-cdn
cd ..
.\.venv\Scripts\python.exe -m http.server 8020 --bind 127.0.0.1 --directory petmind_app\build\web
```

화면 주소: `http://127.0.0.1:8020`. 준비한 입력과 모델이 없으면 해당 기능의 미준비 상태를 표시한다. 가상 장치는 소리·GPIO를 실제로 실행하지 않는다. 승인 후 에이전트가 없으면 30초 뒤 요청이 시간초과된다.

## Gemini 설정

`.env.example`을 참고해 로컬 `.env`에 `GEMINI_API_KEY`를 설정한다. 키를 저장소·채팅·문서에 넣지 않는다. 키만 설정하면 기본 제공자는 Gemini이며, `PETMIND_LLM_PROVIDER=rule`로 명시하면 규칙 모드를 사용한다. 변경 후 백엔드를 재시작한다.

신규 프로젝트 기본 모델은 `gemini-3.5-flash-lite`다. [공식 문서](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash-lite)에 따르면 이전 2.5 모델은 기존 사용 이력이 있는 계정으로 접근이 제한되므로 환경변수로 필요한 모델을 선택한다.

```powershell
.\.venv\Scripts\python.exe -m scripts.verify_gemini
```

Gemini에는 관찰 집계와 검색 기록만 전달한다. 오류·응답 검증 실패·검색에 없는 ID 인용은 규칙 폴백으로 처리하고 실제 제공자를 표시한다.

## 테스트·시연 증거

```powershell
.\.venv\Scripts\python.exe -m pytest tests petmind\backend\tests -q -p no:cacheprovider
.\.venv\Scripts\python.exe -m scripts.verify_flow
.\.venv\Scripts\python.exe -m scripts.verify_media_flow
.\.venv\Scripts\python.exe -m scripts.verify_faults
.\.venv\Scripts\python.exe -m scripts.verify_extras
.\.venv\Scripts\python.exe -m scripts.verify_personalization
cd petmind_app
flutter analyze
flutter test
```

`verify_faults`는 실제 응답 대기 시간초과, `verify_extras`는 같은 길이의 후속 관찰을 확인하므로 각각 약 30초가 필요하다. `verify_faults` 검증 중에는 상시 가상 장치 에이전트를 끈다. 실행 결과 JSON은 `artifacts/`에 기록한다. 실행·수정 내역과 남은 항목은 [현재 상태](docs/STATUS.md)와 파트별 Markdown에 저장한다.

## 구조와 남은 단계

[InterPet4D 적용 결과](docs/27_InterPet4D_적용_평가.md): 실제 자료로 후보를 학습하고 반려견 분리 평가·원본 영상 실행까지 완료했다. 좌표 예측 오차는 줄었으나 영상 성능은 악화해 후보는 별도 보관하고 기존 실행 모델을 유지했다. [추적 ID 재연결·추적 빈도 개선](docs/28_추적_ID_재연결_개선.md) 후에도 보류견 영상의 연속 구간이 10초보다 짧아 예측은 `unknown`이다.

[A2D 공개 행동 영상 실험](docs/29_A2D_공개영상_행동실험.md): 공식 단일 개 행동 영상 189편에서 짧은 궤적 58편을 확보하고 3초 LSTM을 학습했다. 검증 기반 임계값에서 이동 4건을 모두 놓쳐 기본 분류기로 채택하지 않았다. [공식 주석 개 탐지 실험](docs/30_A2D_공식주석_개탐지_평가.md): 주석 585프레임으로 탐지기를 미세조정했고 같은 자료의 탐색적 테스트에서 중복 제거 후 개 박스 재현율이 61.8%→82.4%, 정밀도는 94.4%→87.5%였다. [중복 개 박스 제거](docs/31_중복_개박스_추적개선.md)는 기본 탐지기에 적용해 실제 영상의 추적 구간을 늘렸다. 다른 원본 영상의 4종 행동 정확도 개선은 입증되지 않아 기본 탐지기·분류기는 유지한다. 탐색 중 테스트를 반복했으므로 독립 최종 정확도 수치로 사용하지 않는다.

[실제 공개 데이터 성능 비교](docs/25_실제데이터_성능비교.md): 원본 영상의 이동 감지 재현율은 v1/v2 모두 44.4%(9개 구간). 실제 개선은 미확인이다. 비이동 정답이 없어 전체 정확도로 사용하지 않는다. 추적·카메라 이동과 실제 4종 정답 데이터가 다음 우선순위다.

최신 LSTM·RAG 개선과 한계는 [공개 데이터](docs/22_공개_모션데이터_검증.md), [LSTM v2](docs/23_LSTM_특징_불확실성_개선.md), [RAG v2](docs/24_RAG_기간_의미검색_개선.md)에 기록했다. LSTM의 실제 행동 분류 성능은 아직 검증되지 않았다.

```powershell
.\.venv\Scripts\python.exe -X utf8 -m scripts.prepare_mocap
.\.venv\Scripts\python.exe -X utf8 -m scripts.train_lstm --pretrain-data artifacts/datasets/ai4animation/windows.npz --output artifacts/lstm_v2
.\.venv\Scripts\python.exe -X utf8 -m scripts.evaluate_rag --semantic
.\.venv\Scripts\python.exe -X utf8 -m scripts.verify_rag_v2
```

새로 학습한 모델은 `artifacts/lstm_v2`에 저장한다. 기본 실행 모델을 바꾸려면 기존 `artifacts/lstm/trajectory_lstm.pt`를 백업한 뒤 새 파일을 복사하고 백엔드를 재시작한다. 의미 검색은 `.env`에 `PETMIND_SEMANTIC_SEARCH=on`을 설정한다. 외부 API가 실패하면 키워드 검색으로 폴백하며 화면에 표시한다. 공개 모션은 CC BY-NC 4.0 조건을 확인하고 연구·교육 용도로 사용한다.

```text
pet_monitor/           기존 분석·합성 입력 + WAV·LSTM·추적 어댑터
petmind/backend/       FastAPI·SQLite·기록 검색·MCP·케어 제공자
petmind/device_agent.py 가상 음악 장치 HTTP 왕복
petmind_app/           기존 Flutter 대시보드를 확장한 웹 앱
scripts/               학습·입력 준비·검증·실행
docs/                  파트별 기록·검증 근거
artifacts/             로컬 데이터·모델·평가 산출물 (Git 제외)
legacy/                2026년 9월 시제품과 초기 문서 보관 (현재 실행 경로 아님)
```

실제 Gemini 및 Pi 가상 명령 왕복은 검증했다. 실제 브라우저에서 연속 클릭·시연 영상, Pi 카메라·마이크·물리 재생, 실제 반려견 라벨 기반 정확도·장시간 관찰·케어 효과는 별도 검증이 필요하다. 로컬 개발용 API이며 외부 배포 인증은 아직 구현하지 않았다.
