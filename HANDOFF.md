# Readassi 인수인계 노트 — 명령 2 / 3 진행용

> **이 파일을 새 Claude Code 세션에 업로드하면**, 지금까지의 맥락을 그대로 이어받아
> **명령 2부터** 작업을 시작할 수 있다. 명령 1은 이미 완료되어 `main`에 병합·푸시됨.

---

## 1. 프로젝트 개요

- **Readassi**: Flutter 기반 AI 독서 보조 앱. 스마트폰을 책 위에 거치 → 자동 촬영 →
  OCR → 등장인물 프로필 / 관계도 / 스토리 요약 / AI 질의응답 생성.
- 리포지토리: `github.com/dttchan411/Readassi` (main 브랜치에서 작업)
- Flutter 프로젝트 경로: `readassi_flutter/`
- 등장인물 프로필 / 관계도 / 스토리 요약은 이미 대략 구현됨.
  OCR=Google Vision, 통합 분석=Gemini 2.5 Flash, Q&A=Claude.

---

## 2. 큰 목표 — 손으로 가려진 텍스트 추출

### 확정된 아키텍처
- **선결 작업**: ① MediaPipe 손 감지(온디바이스) ② 온디바이스 OCR(ML Kit 한국어)
- **1단계 (깨끗 프레임 지름길)**: 손이 본문을 안 가린 프레임이 나오면 그 한 장을
  Vision OCR하고 끝.
- **2단계 (줄 단위 텍스트 병합)**: 손이 본문과 겹치면 프레임마다 온디바이스 OCR →
  각 줄의 "깨끗함"을 판정(손 영역 미겹침 + OCR 신뢰도) → 깨끗한 줄을 버퍼에 누적 →
  모든 줄이 모이면 전체 텍스트 조립. **1·2단계는 동시 진행**.
- 이미지 타일 합성 / perspective correction은 **채택하지 않음**(책 곡률·프레임 정합
  문제). 텍스트 레벨 병합이 정합 문제를 우회한다.
- 폴백: 페이지 일관성 체크(페이지 전환 시 버퍼 리셋), 완성 타임아웃 +
  "손을 치워주세요" UI 힌트.

### 작업 방식 — 명령 3개로 얇게 슬라이스
각 명령 = 알고리즘 한 조각 + 그에 맞는 디버그 UI 한 조각. 매 명령마다 실기기 검증.

| 명령 | 내용 | 상태 |
|---|---|---|
| 명령 1 | MediaPipe 손 감지 통합 + 디버그 패널(손 yes/no + 박스) | **완료 (main 병합·푸시)** |
| 명령 2 | 깨끗 프레임 경로 (손 미겹침 → Vision OCR), 디버그에 상태/결과 | **다음 할 일** |
| 명령 3 | 2단계 줄 누적 (온디바이스 OCR), 디버그에 줄별 수집 현황 + 누적 텍스트 | 대기 |

통합 방식 결정: **네이티브 플랫폼 채널** 방식, **Android만** (iOS는 나중에).

---

## 3. 명령 1에서 구현한 것 (완료 · 커밋 `960be9c5`)

| 파일 | 내용 |
|---|---|
| `readassi_flutter/android/app/build.gradle.kts` | `com.google.mediapipe:tasks-vision:0.10.14` 의존성, `.task` 무압축 |
| `readassi_flutter/android/app/src/main/assets/hand_landmarker.task` | MediaPipe 손 모델 (7.8MB) |
| `.../kotlin/com/example/readassi_flutter/HandDetector.kt` | YUV 프레임 → Bitmap → HandLandmarker → 손별 정규화 bbox 반환 |
| `.../kotlin/com/example/readassi_flutter/MainActivity.kt` | `readassi/hand_detection` MethodChannel, 검출은 백그라운드 스레드 |
| `readassi_flutter/lib/src/services/hand_detection_service.dart` | 플랫폼 채널 래퍼 + `HandDetectionResult` / `HandBox` 모델 |
| `readassi_flutter/lib/src/screens/scan_screen.dart` | 헤더 디버그 토글, `_handleCameraImage`에 700ms 스로틀 손 감지 호출 |
| `readassi_flutter/lib/src/screens/scan_camera_view.dart` | 디버그 패널 + 프리뷰 위 손 박스 오버레이 |

### 명령 2/3이 활용할 핵심 API
- `HandDetectionService.detect(CameraImage)` → `HandDetectionResult`
  - `detected`(bool), `handCount`(int), `boxes`(List<HandBox>, 정규화 0~1
    `left/top/right/bottom`), `latencyMs`(int), `error`(String?)
- `scan_screen.dart`:
  - `_handleCameraImage(CameraImage)` — 이미지 스트림 콜백, **자동 촬영 모드에서만** 실행.
  - `_maybeRunHandDetection(image, now)` — 700ms 스로틀. **현재는 `_debugPanelEnabled`일
    때만** 호출됨 → 명령 2에서는 손 감지가 촬영 판단을 **게이팅**해야 하므로,
    디버그 토글과 무관하게 동작하도록 바꿔야 함.
  - `_handResult` — 최신 손 감지 결과 보관 필드.

### 검증 상태 — **중요**
- Dart는 `dart analyze` 통과.
- **네이티브(Kotlin)는 실기기 빌드로만 검증 가능 → 아직 미검증.**
- → 명령 2를 진행하기 전에 **먼저 명령 1을 실기기에서 검증**할 것 (아래 4번).
  빌드/감지 실패 시 그것부터 고친 후 명령 2로.

---

## 4. 명령 1 실기기 검증 방법

1. **Windows 개발자 모드 ON** 필요(symlink). `start ms-settings:developers`.
2. Android 기기에 빌드 → 책 스캔 화면 진입.
3. 헤더 우측 **벌레 아이콘** 탭 → 디버그 패널 표시.
4. **촬영 시작** 후 카메라에 손을 넣어 → `손 감지: 예` + 초록 박스 확인.

### 위험 지점
- MediaPipe 버전 `0.10.14` — Gradle 해석/빌드 실패 시 버전 상향(0.10.18+).
- 손 박스가 회전/좌우반전될 수 있음(카메라 센서 방향 vs 프리뷰 변환 차이) →
  어긋나면 어떻게 어긋나는지 확인 후 좌표 변환 추가.
- `tasks-vision`가 minSdk 24 요구 가능 — 현재 minSdk=max(flutter기본,21),
  flutter 기본이 24라 보통 OK.

---

## 5. 명령 2 — 다음 할 일 (깨끗 프레임 경로)

**명령 프롬프트(그대로 사용):**
> "손이 본문과 안 겹치면 촬영해서 Vision OCR. 디버그 패널에 현재 상태와 OCR 결과를
> 표시해라. 그 외엔 아무것도 하지 마라."

**해야 할 일 요약:**
- 손 감지를 촬영 판단의 **게이트**로 연결. 밝기 게이트가 안정 → 촬영하려는 순간,
  최신 손 감지 결과에서 손 영역이 본문 영역과 안 겹치면 → 깨끗한 프레임으로 보고
  기존 Vision OCR 흐름(`_captureSinglePage` → `_enqueueOcr`) 진행.
- 손이 본문과 겹치면 → 깨끗한 프레임이 아님(명령 3에서 누적 처리할 영역). 명령 2
  단계에서는 일단 "겹침 → 대기/표시"까지만.
- 디버그 패널에 현재 상태(`움직임 감지중` / `안정-손검사중` / `깨끗-OCR중` /
  `손 겹침-대기`)와 OCR 결과를 표시.
- **1단계와 2단계는 동시 진행** 설계임을 기억(명령 3에서 누적 경로가 붙음).
- 손 감지가 디버그 토글과 무관하게 촬영 중 항상 돌도록 바꿔야 함(명령 1에서는
  `_debugPanelEnabled`일 때만 돌게 해놨음).

---

## 6. 명령 3 — 그 다음 (2단계 줄 누적)

**명령 프롬프트(그대로 사용):**
> "손이 본문과 겹치면 프레임마다 온디바이스 OCR로 깨끗한 줄을 버퍼에 모으고,
> 디버그 패널에 줄별 수집 현황과 누적 텍스트를 실시간 표시해라."

온디바이스 OCR은 ML Kit 한국어 인식 사용. 네이티브에 `com.google.mlkit:text-recognition-korean`
의존성이 이미 `build.gradle.kts`에 있음(Flutter 패키지는 아직 없음).

---

## 7. 기존 코드 맥락 (페이지 감지 / OCR 흐름)

`scan_screen.dart`:
- **페이지 넘김 감지**: 프레임 휘도 64점 샘플링 → 직전 프레임과 차분. 차이 < 12면
  "정지", 1.2초 안정 + 직전 촬영 후 2초 경과 시 `_captureSinglePage()` 호출.
  ("움직임 → 정지 → 촬영" 트리거. 명령 1에서 이 로직은 건드리지 않음.)
- **OCR 흐름**: `_captureSinglePage` → `takePicture` → `_enqueueOcr(bytes)` →
  Google Vision `DOCUMENT_TEXT_DETECTION`. OCR 후보 dedup 로직(`_PageCandidate`,
  `_looksLikeDuplicatePage`, `_looksUncertainComparedToCandidate`)이 있음.
- 분석: `_performAnalysis` → Gemini 통합 분석 → (옵션) Claude 인물/관계 재분석.

---

## 8. 환경 메모

- Flutter SDK: `C:\flutter` (PATH에 없음. `C:\flutter\bin\flutter.bat` /
  `C:\flutter\bin\dart.bat` 직접 호출).
- `.env` 파일 필요(API 키, gitignore 대상 → git으로 안 넘어감). 노트북에 별도로 둘 것.
- 모델 재다운로드(필요 시):
  `https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task`
  → `readassi_flutter/android/app/src/main/assets/hand_landmarker.task`
- 작업 공간: **메인 체크아웃에서 직접 작업**(`C:\ai-reading\Readassi`). 사용자는
  Claude Code의 worktree 자동 격리를 원치 않음 — 기존 폴더에서 바로 수정 선호.

---

## 9. 협업 규칙 (사용자 선호)

- 요청하지 않은 코드 수정 / 리팩터링 금지. 시킨 것만 수행한다.
- 코드 검토를 요청받으면 진단·제안만 제공하고, 실제 수정은 명시적 지시가 있을 때까지
  보류한다.
- 큰 갈림길(아키텍처 선택 등)은 코드를 쓰기 전에 먼저 물어본다.

---

## 10. Git 상태 / 노트북 셋업

- 명령 1 코드는 `main`에 병합·푸시 완료 (커밋 `960be9c5`).
- 노트북에서:
  ```
  git pull origin main
  flutter pub get
  ```
  그리고 `.env` 파일이 노트북에도 있는지 확인.
- 이 `HANDOFF.md`는 커밋하지 않음 — 파일/내용을 새 Claude 세션에 직접 업로드해서 사용.
