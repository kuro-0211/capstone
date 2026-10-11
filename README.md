# PetMind 캡스톤 — 반려견 관찰·개별 기록 기반 케어 시제품

> **처음 받는 사람이 설치부터 시연까지 재현할 수 있도록** 현재 코드와 검증 결과를 한곳에 정리했습니다.
> 기준: 2026-10-11 · 개발 환경: Windows 11 / Python 3.12 / Flutter · 저장소: [kuro-0211/capstone](https://github.com/kuro-0211/capstone)
>
> 처음 읽는다면 **0장 → 1장 → 6장 → 8장** 순서로 보세요. 실행 중 막히면 **12장**, 수치의 근거와 한계는 **11장**을 확인하세요.

---

## 목차

0. [한눈에 보기](#0-한눈에-보기)
1. [블록도](#1-블록도)
2. [하드웨어·네트워크](#2-하드웨어네트워크)
3. [소프트웨어·버전](#3-소프트웨어버전)
4. [AI 분석: 영상 LSTM·기록 RAG](#4-ai-분석-영상-lstm기록-rag)
5. [저장소 구조](#5-저장소-구조)
6. [설치 — Windows PC](#6-설치--windows-pc)
7. [설치 — Raspberry Pi 가상 장치 (선택)](#7-설치--raspberry-pi-가상-장치-선택)
8. [사용법 (매일 하는 순서)](#8-사용법-매일-하는-순서)
9. [API·MCP·명령 인터페이스](#9-apimcp명령-인터페이스)
10. [설정값과 선택 이유](#10-설정값과-선택-이유)
11. [검증 결과](#11-검증-결과)
12. [문제 해결 (확인한 증상)](#12-문제-해결-확인한-증상)
13. [남은 일](#13-남은-일)
14. [부록: 명령 모음](#14-부록-명령-모음)

---

## 0. 한눈에 보기

### 해결하려는 문제

반려견의 영상 움직임과 소리만 보고 감정·질환을 단정하기 어렵다. PetMind는 관찰 신호를 **반려견별 기록**으로 남기고, 과거 관찰·보호자 의견을 검색 근거로 제시해 보호자가 케어 제안을 검토하도록 돕는다. 음악 실행은 보호자 승인 후에만 요청한다. **급식기는 현재 범위에서 제외**한다.

### 지금 되는 것 (2026-10-11)

| 단계 | 현재 상태 | 검증 범위 |
|---|---|---|
| 관찰 | 합성 시나리오·준비된 공개 음원/영상 입력을 SQLite에 저장 | 실제 HTTP 흐름 확인 |
| 영상 | YOLOv8n 탐지·ByteTrack 추적·10초 LSTM 추론, 불충분한 구간은 `unknown` | 공개 영상 실행; 실제 4종 행동 정확도 미검증 |
| 음성 | WAV 에너지 기반 **짖음 후보** 표시 | 공개 음원 20개 파일럿; 짖음 확정 분류기 아님 |
| 개별 기록 RAG | 같은 반려견의 과거 기록을 MCP로 검색, 기간·근거 ID 저장 | 실제 Gemini·임베딩 호출 및 합성 사례 확인 |
| 화면 | Flutter에서 관찰·근거·제안·승인·이력·프로필·피드백 표시 | Flutter 테스트·웹 빌드; 브라우저 연속 시연 영상 미확보 |
| 실행 | 승인된 음악 명령의 요청·수신·완료·실패·시간초과 | PC와 실제 Pi에서 **가상 명령** 왕복; 스피커/GPIO 미사용 |

### 하루 사용 3줄 요약

```powershell
# 저장소 루트, 각각 별도 터미널: 백엔드 → 가상 장치 → 화면
.\.venv\Scripts\python.exe -m uvicorn petmind.backend.main:app --host 127.0.0.1 --port 8010
.\.venv\Scripts\python.exe -m petmind.device_agent
cd petmind_app; flutter run -d chrome --web-port 8021
```

최초 설치와 `.env`는 6장을 따른다. 준비된 모델·공개 입력이 없으면 해당 화면은 미준비 상태가 정상이다.

---

## 1. 블록도

### 1-1. 전체 배치

```text
공개 영상/좌표 ─► 개 탐지·추적 ─► LSTM 행동 후보 ─┐
공개 WAV ─────────────────► 짖음 후보 이벤트 ────┤
합성 시연 ───────────────────────────────────────┤
                                                ▼
                                    FastAPI 관찰 API ─► SQLite
                                           │             │
                                           │        반려견별 과거 기록
                                           └────► MCP 검색·통계·케어 이력
                                                        │
                                                Gemini 또는 규칙 제공자
                                                        ▼
                                       Flutter 근거·인용·제안 화면
                                                        │ 보호자 승인
                                                        ▼
                                  FastAPI 명령 상태 ─► 가상 음악 장치(PC/Pi)
                                                        │ 결과 응답
                                                        └────► SQLite·화면 이력
```

### 1-2. 관찰에서 가상 실행까지

1. `POST /demo/observe` 또는 `POST /media/observe`가 출처를 붙인 관찰을 저장한다.
2. `POST /care/evaluate`가 **같은 반려견·현재보다 과거인 기록**을 MCP로 조회하고, 검색 결과를 Gemini 또는 규칙 제공자에 전달한다.
3. 제안과 근거 ID가 DB에 남는다. 화면은 제공자가 Gemini인지 규칙/폴백인지 보여준다.
4. 음악을 승인하면 명령이 `requested`가 된다. 가상 장치가 `acknowledged` 후 `completed` 또는 `failed`를 보고한다. 무응답은 `timed_out`이다.

공개 영상과 WAV를 함께 시연할 때 두 파일은 **별도 출처**다. 실제 동시 녹화나 실제 반려견 감정 판정으로 해석하지 않는다.

---

## 2. 하드웨어·네트워크

| 항목 | 현재 구성 | 범위 |
|---|---|---|
| 개발 PC | Windows 11, Python 3.12, Flutter 웹 | 백엔드 `127.0.0.1:8010`, 화면 `localhost:8021` |
| 저장소 DB | PC 로컬 SQLite `petmind.db` | Git에서 제외, 재시작 후 기록 유지 |
| Raspberry Pi | `/home/pi/Desktop/PetMind_Test`, Python 3.13.5 | SSH 역방향 터널로 **가상 장치 명령** 왕복 확인 |
| 외부 서비스 | Gemini 생성·임베딩 API | 로컬 `.env`의 키가 있을 때 사용; 실패 시 폴백 표시 |
| 카메라·마이크·스피커 | 실장비 입력/재생 미연결 | 현재 시연은 준비된 파일과 가상 장치 |

Pi 시험은 필수 실행 경로가 아니다. SSH 별칭 `raspberrypi-ai`는 시험 환경의 설정이며 다른 PC에서는 자신의 호스트 설정이 필요하다.

---

## 3. 소프트웨어·버전

| 구분 | 현재 개발·검증 환경 | 역할 |
|---|---|---|
| Python | 3.12.10 | 분석·FastAPI·MCP·가상 장치·평가 |
| FastAPI / SQLAlchemy / SQLite | 버전 범위는 `requirements-core.txt` | HTTP API·기록 보존 |
| PyTorch / Ultralytics / OpenCV | 버전 범위는 `requirements-vision.txt` | LSTM·영상 탐지·추적 |
| 공식 MCP Python SDK | `mcp==2.3.0` | 별도 stdio 프로세스의 읽기 전용 도구 |
| Flutter / Dart | 3.47.5 / 3.13.4 | 보호자 웹 화면 |
| Raspberry Pi 시험 환경 | Debian 13.5, Python 3.13.5 | `requests` 기반 가상 장치 |

이번 Windows 환경에서 해결된 전체 Python 의존성 버전은 `requirements-lock.txt`에 기록했다. 다른 운영체제의 완전 재현성까지 보장하는 잠금 파일은 아니다.

---

## 4. AI 분석: 영상 LSTM·기록 RAG

| 역할 | 현재 방식 | 판단에 필요한 한계 |
|---|---|---|
| 영상 | 개 박스 탐지·ID 추적 후 시계열 좌표를 LSTM에 입력 | 추적이 10초 미만이면 `unknown`; 실측 4종 정확도 없음 |
| 음성 | WAV 에너지 변화로 짖음 **후보** 탐지 | 비개 소리 오탐이 있어 짖음 확정 불가 |
| 기록 검색 | SQLite의 반려견·기간 필터 → 키워드, 선택적으로 Gemini 임베딩 → MCP 도구 3개 | 검색 실패와 기록 없음, 근거와 배경 기록을 구분 |
| 제안 생성 | 검색·통계·케어 이력을 Gemini에 전달, 유효하지 않은 인용·호출 실패 시 규칙 폴백 | 케어 효과·의학적 판단을 검증한 시스템이 아님 |

운영 영상 모델은 기존 체크포인트를 유지한다. InterPet4D·A2D 후보는 일부 좌표 예측·개 박스 탐지 지표가 좋아졌지만 **독립적인 실제 4종 행동 분류 개선은 입증되지 않았다**. [실제 데이터 평가](docs/25_실제데이터_성능비교.md), [A2D 탐지 평가](docs/30_A2D_공식주석_개탐지_평가.md), [추적 개선](docs/31_중복_개박스_추적개선.md)에 수치와 한계를 기록했다.

RAG는 같은 반려견의 과거 기록을 시간으로 먼저 제한하고 관련 기록을 선택해 **기록 ID를 인용**한다. 자체 작성 20개 질문의 Recall@5는 개선됐지만 실제 보호자 질문 성능은 별도 평가가 필요하다. [RAG 평가와 폴백 기록](docs/24_RAG_기간_의미검색_개선.md)을 참고한다.

**API 키:** `.env.example`을 복사한 로컬 `.env`에 `GEMINI_API_KEY`를 설정한다. 키는 Git·문서·채팅에 넣지 않는다. 키가 없으면 규칙 제공자로 시연할 수 있다. Gemini 호출·검증 실패 시에는 폴백 사유가 표시된다.

---

## 5. 저장소 구조

```text
capstone/
├── README.md                 이 문서: 설치·사용·검증·문제 해결
├── AGENTS.md                 개발 범위와 검증 원칙
├── .env.example              비밀값 없는 설정 예시
├── requirements-*.txt        Python 의존성 (core / vision / Windows lock)
├── pet_monitor/              음성·영상·좌표·LSTM 분석
├── petmind/
│   ├── backend/              FastAPI·SQLite·MCP·Gemini/규칙 제공자
│   └── device_agent.py       PC/Pi 호환 가상 음악 장치
├── petmind_app/              Flutter 보호자 화면
├── scripts/                  학습·공개 입력 준비·평가·통합 검증
├── tests/                    분석·추적·LSTM 회귀 테스트
├── docs/                     작업 기록·평가 근거
│   └── evidence/            공개 가능한 요약 JSON·그림·렌더링 캡처
└── legacy/                   이전 시제품·초기 문서 (현재 실행 경로 아님)
```

**저장소 밖/무시되는 로컬 파일:** `.env`, `petmind.db`, `device_commands.db`, `artifacts/`의 원본 데이터·모델·평가 산출물, Flutter 빌드 결과. 이전 급식·센서 시제품은 [`legacy/`](legacy/README.md)에서만 참고한다.

---

## 6. 설치 — Windows PC

### 6-1. 준비·복제

Python **3.12**, Git, Flutter를 설치하고 `flutter --version`으로 Flutter 명령이 실행되는지 확인한다.

```powershell
git clone https://github.com/kuro-0211/capstone.git
cd capstone
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-vision.txt
flutter --version
```

`py -3.12`가 없다면 해당 Python 실행 파일로 가상 환경을 만든다. 영상·학습 없이 합성 관찰/API만 시험할 때는 `requirements-core.txt`를 대신 설치할 수 있다.

### 6-2. 선택 설정

```powershell
Copy-Item .env.example .env
# Gemini를 쓸 때만 .env의 GEMINI_API_KEY에 본인 키를 입력하고 백엔드를 재시작
```

키가 없는 기본 시연은 규칙 제공자를 사용한다. 예제의 의미 검색 설정은 키가 없으면 키워드로 폴백한다. 실제 Gemini 경로는 키 설정 후 `scripts.verify_gemini`로 확인한다.

### 6-3. 공개 입력·모델 준비 (선택)

```powershell
.\.venv\Scripts\python.exe -m scripts.train_lstm
.\.venv\Scripts\python.exe -m scripts.prepare_media
.\.venv\Scripts\python.exe -m scripts.evaluate_audio
.\.venv\Scripts\python.exe -m scripts.prepare_davis
.\.venv\Scripts\python.exe -m scripts.evaluate_video
```

DAVIS 공식 이미지 자료는 약 **833MB**다. 출처·조건·해시는 [`docs/evidence/public_inputs.json`](docs/evidence/public_inputs.json)에 기록했다. 모델과 원본 파일은 `artifacts/`에 생성되며 GitHub에는 포함하지 않는다. 합성 시연만 할 때는 이 단계를 건너뛸 수 있다.

---

## 7. 설치 — Raspberry Pi 가상 장치 (선택)

PC만으로 승인·가상 실행 흐름을 시연할 수 있다. Pi 왕복은 별도 실험이며 **실제 음악·GPIO 실행이 아니다**. 기존 Pi 테스트 폴더가 있는 환경에서 PC API를 실행한 뒤 SSH 역방향 터널을 연다.

```powershell
ssh -N -R 127.0.0.1:18010:127.0.0.1:8010 -o ExitOnForwardFailure=yes raspberrypi-ai
```

Pi의 `/home/pi/Desktop/PetMind_Test`에서 `sh run_once.sh` 또는 전용 `.venv`의 `device_agent.py`를 실행한다. 폴더 구성·재현 명령은 [Pi 실행 안내](scripts/PI_TEST_README.md)와 [왕복 기록](docs/20_Pi_바탕화면_왕복테스트.md)을 따른다. Pi 시험 중에는 PC 에이전트를 중지해 명령 처리 주체를 분리한다.

---

## 8. 사용법 (매일 하는 순서)

1. 저장소 루트에서 백엔드를 실행하고 `http://127.0.0.1:8010/health`가 `healthy`인지 확인한다.
2. 다른 터미널에서 가상 장치를 실행한다. Pi 시험이면 7장의 Pi 에이전트로 대체한다.
3. `petmind_app`에서 `flutter pub get` 후 `flutter run -d chrome --web-port 8021`로 화면을 연다.
4. 반려견을 선택하고 **합성 과거 기록 준비** → `calm`, `anxious`, `bored_pacing` 중 하나를 관찰한다. 관찰·근거·제안의 입력 출처를 확인한다.
5. 음악 제안이 있는 경우 보호자가 승인한다. 요청 → 장치 응답 → 완료/실패와 타임라인을 확인한다. 음악 제안이 없으면 승인할 명령도 없다.
6. 공개 음원·영상 시연은 6-3의 파일 준비 후 화면에서 선택한다. 서로 다른 원본을 조합한 **합성 시연**임을 함께 표시한다.

API 문서: `http://127.0.0.1:8010/docs`. Flutter의 기본 API 주소는 `http://localhost:8010`이며 다른 호스트에서 열 때 `--dart-define=PETMIND_API_BASE=http://서버주소:8010`으로 바꾼다. 현재 백엔드 CORS와 바인딩은 로컬 개발용이다. [Flutter 렌더링 캡처](docs/evidence/flutter_dashboard_render.png)는 실제 브라우저 클릭 녹화가 아니다.

---

## 9. API·MCP·명령 인터페이스

| 인터페이스 | 대표 경로·도구 | 용도 |
|---|---|---|
| 상태·관찰 | `GET /health`, `POST /observations`, `GET /observations` | DB/제공자 상태와 반려견별 관찰 |
| 시연 입력 | `POST /demo/seed`, `POST /demo/observe`, `GET /media/catalog`, `POST /media/observe` | 합성 이력·준비된 공개 입력 |
| 제안·승인 | `POST /care/evaluate`, `GET /care/history`, `POST /care/{id}/approve` | 근거 검색 후 제안, 보호자 승인 |
| 가상 장치 | `GET /care/actions/pending`, `POST /care/actions/{command_id}/ack` | 명령 조회·수신·완료/실패 보고 |
| 이력·추가 기록 | `GET /timeline`, `GET /metrics`, `/pets/{pet_id}/profile`, `/feedback` | 타임라인·수치·프로필·보호자 의견 |
| MCP stdio | `search_observations`, `get_observation_stats`, `get_care_history` | 같은 반려견의 과거 기록·집계·케어 이력 읽기 |

`petmind/device_agent.py`는 2초 간격으로 대기 명령을 조회하고 명령 ID를 로컬 SQLite 캐시에 남긴다. 승인 전에는 장치 명령이 없다. 무응답 만료는 기본 30초다. 전체 요청·응답 계약은 `/docs`와 [`schemas.py`](petmind/backend/schemas.py)를 따른다.

---

## 10. 설정값과 선택 이유

| 설정 | 기본/예시 | 의미 |
|---|---|---|
| `GEMINI_API_KEY` | 빈 값 | 있으면 Gemini 자동 선택, 없으면 규칙 제공자 |
| `PETMIND_LLM_PROVIDER` | 키 유무에 따라 `gemini`/`rule` | 시연 제공자 명시 전환 |
| `PETMIND_GEMINI_MODEL` | `gemini-3.5-flash-lite` | 계정에서 사용 가능한 모델로 변경 가능 |
| `PETMIND_RETRIEVAL_MODE` | `mcp` | 별도 stdio 검색 도구 사용 |
| `PETMIND_SEMANTIC_SEARCH` | 코드 기본 `off`, 예제 `on` | 임베딩 의미 검색; 실패 시 키워드 폴백 |
| `PETMIND_DATABASE_URL` | 루트 `petmind.db`의 SQLite URL | 관찰·제안·명령 영속 저장 |
| `PETMIND_ACTION_TIMEOUT_SECONDS` | `30` | 장치 무응답 요청 만료 기준 |

운영 영상 체크포인트의 기본 위치는 `artifacts/models/yolov8n.pt`, `artifacts/lstm/trajectory_lstm.pt`다. 후보 모델을 자동으로 덮어쓰지 않는다. LSTM의 `unknown`은 추적·시간·신뢰 조건 부족을 드러낸다. 실제 기본값은 [`settings.py`](petmind/backend/settings.py)를 따른다.

---

## 11. 검증 결과

| 항목 | 확인 결과 | 해석·근거 |
|---|---|---|
| 새 저장소 복제본 Python | **65 passed, 1 skipped** | 모델 체크포인트 미포함; 로컬 모델 환경은 66 passed |
| Flutter | 테스트 **2 passed**, `flutter analyze` 오류 없음, release 웹 빌드 성공 | 실제 브라우저 클릭 영상과 별개 |
| HTTP·MCP·가상 장치 | 합성 3종 연속 처리, MCP 도구 3개씩 호출, 승인 명령 완료 | [통합 기록](docs/07_통합시연_회귀검증.md) |
| 실제 Gemini RAG | 임베딩→MCP→Gemini→과거 기록 ID 인용 확인 | 합성 입력; [호출 결과](docs/evidence/rag_v2_real_integration.json) |
| RAG 검색 평가 | 자체 작성 20개 질문 Recall@5: 이전 25% → 의미 검색 100% | 실제 보호자 질문 성능 아님; [평가 방법](docs/24_RAG_기간_의미검색_개선.md) |
| 공개 음원 파일럿 | 개 소리 5/5 후보 감지, 비개 소리 15개 중 3개 오탐 | 에너지 기반 후보; [결과](docs/evidence/audio_pilot_summary.json) |
| 공개 원본 영상 이동 평가 | 기존/후보 LSTM 모두 **4/9 = 44.4% 재현율** | 이동 정답만 있는 9구간; 전체 4종 정확도 아님; [평가](docs/25_실제데이터_성능비교.md) |
| PC↔Pi | 완료·실패·중복·늦은 응답·약 30초 시간초과 확인 | 물리 재생 아님; [결과](docs/evidence/pi_verification.json) |

합성 LSTM 400개 테스트의 100%는 합성 분포 내 수치다. 공개 영상에서는 추적 구간이 부족해 `unknown`이 많다. 최신 구현·검증 상태는 [`docs/STATUS.md`](docs/STATUS.md)에 있다.

---

## 12. 문제 해결 (확인한 증상)

| 증상 | 원인·확인 | 해결 |
|---|---|---|
| 화면은 열리지만 API 연결 실패 | 백엔드 미실행 또는 Flutter의 API 주소가 다름 | `/health` 확인, `PETMIND_API_BASE` 지정. 다른 기기 접속은 8장 제한 확인 |
| Gemini 대신 `rule`/`rule-fallback` 표시 | 키 없음·호출 실패·검색에 없는 ID 인용 | 로컬 `.env`와 `/health` 확인, `scripts.verify_gemini` 실행. 폴백을 Gemini 성공으로 세지 않음 |
| 의미 검색이 키워드로 폴백 | 키·설정 또는 임베딩 API 실패 | `PETMIND_SEMANTIC_SEARCH`, 키, 서버 재시작과 폴백 이유 확인 |
| 영상 미리보기 404 / 분석 409 | 준비된 영상·평가 JSON 없음 | 6-3의 `prepare_davis`, `evaluate_video` 실행 |
| 공개 음원 목록이 비어 있음 | `artifacts/media/manifest.json` 미생성 | 6-3의 `prepare_media` 실행 |
| LSTM이 `unknown` 반환 | 체크포인트 없음 또는 추적·10초 입력 조건 부족 | 모델 파일과 추적 구간을 확인하고 억지 라벨을 만들지 않음 |
| 승인 명령이 `timed_out` | 가상 에이전트가 처리하지 않음 | 에이전트·API 연결 확인. Pi 시험이면 터널·PC 에이전트 중지 확인 |

자세한 장애 기록은 [실행 전 확인](docs/12_실행_배포전_확인.md), [장치 재전송](docs/13_장치_동시실행_재전송.md), [Pi 시험](docs/20_Pi_바탕화면_왕복테스트.md)에 있다.

---

## 13. 남은 일

- [ ] **P0 — 시연 완결:** 실제 브라우저 연속 클릭·녹화, 새 환경 설치/복구 절차, 입력·출처·폴백 표시 점검.
- [ ] **P0 — 실제 행동 평가:** 고정 카메라의 정지·이동·회전·왕복 시간별 정답과 10초 이상 이어지는 개별 개체 추적 데이터 확보. coverage와 4종 정확도를 분리 평가.
- [ ] **P1 — 실장비 연동:** Pi 카메라·마이크 입력과 물리 음악 재생, 재부팅·네트워크 장애 복구 확인.
- [ ] **P1 — 개별 케어 검증:** 장기 관찰·실제 보호자 피드백으로 RAG 무관 근거율과 제안 유용성 평가.
- [ ] **P2 — 운영화:** 다중 사용자 인증·배포, 대량 기록 검색 지연과 저장 정책 검토.

현재 실측을 전체 행동 정확도나 음악의 인과적 케어 효과로 발표하지 않는다. 작업 기록은 [`docs/STATUS.md`](docs/STATUS.md), [VS Code 인계](VSCODE_HANDOFF.md)에 있다.

---

## 14. 부록: 명령 모음

저장소 루트에서 실행한다. HTTP 검증은 먼저 백엔드를 켜야 한다.

```powershell
# 전체 Python 회귀 검증
.\.venv\Scripts\python.exe -m pytest tests petmind\backend\tests -q -p no:cacheprovider

# 백엔드·MCP·승인·가상 장치 HTTP 왕복
.\.venv\Scripts\python.exe -m scripts.verify_flow
.\.venv\Scripts\python.exe -m scripts.verify_media_flow
.\.venv\Scripts\python.exe -m scripts.verify_rag_v2

# Flutter 정적 검사·화면 테스트·웹 빌드
cd petmind_app
flutter pub get
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn
```

`verify_media_flow`에는 6-3의 공개 입력이 필요하다. 일부 검증은 실제 Gemini 키와 호출 비용이 필요하므로 실행 전 `.env`를 확인한다. 원본 데이터·체크포인트·개인 DB는 저장소에 넣지 않는다.

> 문서와 실행 결과가 다르면 **실제 코드와 재현된 결과**를 기준으로 README와 검증 기록을 함께 고친다.
