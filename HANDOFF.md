# Readassi 인수인계 노트 — 명령 3(좌우분리 띠) 진행용

> **이 파일을 새 Claude Code 세션에 주면** 지금까지 맥락을 그대로 이어받는다.
> 작업 폴더 `C:\Readassi`, Flutter 프로젝트 `readassi_flutter/`.
> **현재 위치: 명령 3 — 줄 재구성·책등 자동감지·해상도·스티칭 품질투표까지 구현 완료.
> 줄 재구성·책등감지·해상도는 실기기 검증됨. 스티칭 품질투표는 코드·analyze만
> 통과, 아직 실기기 미검증(2번·8번 참조). 다음 세션은 스티칭 검증부터 한다.**

---

## 1. 프로젝트 개요

- **Readassi**: Flutter 기반 AI 독서 보조 앱. 스마트폰을 책 위에 거치 → 자동 촬영 →
  OCR → 등장인물 프로필 / 관계도 / 스토리 요약 / AI 질의응답 생성.
- 리포지토리: `github.com/dttchan411/Readassi` (main 브랜치)
- OCR=Google Vision(클라우드), 통합 분석=Gemini 2.5 Flash, Q&A=Claude.
- 등장인물/관계도/요약 기능은 이미 대략 구현돼 있음.

## 2. 큰 목표 — 손으로 가려진 텍스트 추출

사용자가 손으로 책을 짚으며 읽을 때, 손에 가려진 부분도 복원해 한 페이지를 완성한다.
작업을 명령 단위로 얇게 슬라이스하고, **매 명령/단계마다 실기기 빌드 검증**한다.

| 명령 | 내용 | 상태 |
|---|---|---|
| 명령 1 | MediaPipe 손 감지 통합 + 디버그 패널 | **완료 · main 커밋 `960be9c5` · 검증됨** |
| 명령 2 | 손 미겹침 → Vision 전체 OCR + 손 추적 래치 + 하단여백 게이트 | **완료 · 검증됨 · 미커밋** |
| 명령 3 | 좌우분리 가로 띠 수집 (아래 4~8번) | **구현 완료 · 일부만 검증 · 미커밋** |

> Git 상태: 명령 1만 `main`에 커밋됨. 명령 2·3 변경은 **전부 미커밋 작업본**.

---

## 3. 명령 2 — 완료된 것 (검증됨)

손이 본문을 안 가리면 페이지 전체를 한 장으로 촬영해 Vision OCR 하는 경로.
- 손 감지를 촬영 게이트로 연결. 손 검출 시 차단, 미검출 시 촬영.
- **손 추적 래치**: MediaPipe가 부분 가림 손을 놓치는 문제 → `HandDetector.kt`를
  `RunningMode.VIDEO`로 추적 + Dart 래치(`_handLatched`)로 검출 끊겨도 유지.
- **하단여백 위치 게이트**: 손이 화면 하단 여백(기본 80% 아래)에만 있으면 본문을
  안 가린 것으로 보고 촬영 허용. 경계는 디버그 패널 슬라이더(`_bottomRegionTop`)로 조절.

## 4. 명령 3 — 방식 변천사 (중요)

1. **원안(줄 단위 온디바이스 OCR 누적, ML Kit) — 폐기.** 매 프레임 OCR이 출렁여 실패.
   `OnDeviceOcr.kt` / `on_device_ocr_service.dart` 삭제됨. `build.gradle.kts`의
   `mlkit text-recognition-korean` 의존성은 미사용(정리 가능).
2. **가로 띠 + centerY 비닝(`_harvestBands`) — 폐기.** 좌표계 불일치 버그.
3. **현재 = 좌우분리 크롭 + 겹침 스티칭.** 띠를 잡으면 그 가로 구간을 책등 기준
   좌·우로 잘라 각각 OCR하고, 캡처별 세그먼트를 겹침 스티칭으로 병합. (8-2의
   own-band 비닝안은 채택하지 않음 — 책 흔들림엔 내용기반 스티칭이 더 강함.)

## 5. 명령 3 — 현재 구현된 것

`readassi_flutter/lib/src/screens/scan_screen.dart`. 흐름:

```
_handleCameraImage (안정 프레임)
  → 손이 본문 가림? → _collectCleanBands()
      → 손 안 가린·미수집 띠의 첫 연속구간[start..end] 찾기 → _captureBandFrame(start,end)
          → takePicture → _decodeOriented(EXIF 회전 반영)
          → (첫 띠 캡처면) _detectSpineX로 책등 가로위치 자동 감지
          → _cropEncode로 [띠 세로구간]을 좌(0~_spineX)·우(_spineX~1)로 크롭
          → 좌·우 각각 _ocrLines(_getVisionLines) → Vision OCR
          → _BandSegment(bandStart,bandEnd,leftLines,rightLines) 저장
      → 모든 띠 수집되면 _assembleAndSaveBands()
          → 세그먼트를 띠 순서로 정렬 → 좌/우 컬럼 각각 _stitchColumn으로 스티칭
          → [왼쪽 페이지 전체 + 오른쪽 페이지 전체] 순으로 조립 → 원본 파일 append
  → 손이 본문 안 가림 → _captureSinglePage() (명령 2 전체 촬영)
```

### 5-A. 줄 재구성 — 문제 B 해결 (★ 실기기 검증됨)
`_getVisionLines`가 줄바꿈을 Vision의 `detectedBreak`에 의존하던 것을 폐기.
좁은 크롭에서 Vision이 줄 끝을 `SPACE`로 잘못 표시해 두 줄이 합쳐지는 버그였음.
**이제 단어 경계상자 좌표로 줄을 직접 끊는다**:
- 1단계: 문단별로 모든 단어를 모음(`_OcrWord` = 텍스트+경계상자).
- 2단계: 단어 높이 중앙값으로 임계값 스케일을 잡음.
- 3단계: 단어를 읽기순으로 보며 ① X가 왼쪽으로 리셋(`minX < 이전minX - 단어높이`)
  되거나 ② Y가 한 줄 높이(×0.7) 이상 아래로 점프하면 새 줄로 끊음.
- 두 신호의 상보성이 핵심: X가 크게 다를 땐 X리셋(세로 기울기 무관)이 잡고,
  X가 비슷할 땐 두 단어가 같은 X라 기울기 영향이 0이라 Y점프가 깨끗하게 잡음.
  → 카메라가 살짝 기울어도 줄이 안 깨진다.

### 5-B. 카메라 해상도 (★ 검증됨)
`_initCamera`의 `ResolutionPreset.medium` → `high`. 글자 노이즈 완화.

### 5-C. 책등 자동 감지 + 수동 보정 (C 방식, ★ 실기기 검증됨)
- `_detectSpineX(img.Image)`: 펼친 책의 책등 골은 글자가 없어 가로 명암변화
  (텍스처)가 최소인 세로 컬럼이다. 폭 480으로 축소 후 가로 중앙 30~70% 구간에서
  텍스처 최소 컬럼을 찾는다. 첫 띠 캡처에서 1회 감지(수동 보정 중이면 건너뜀).
- `_spineX`는 더 이상 상수가 아니라 인스턴스 필드. `_spineManualOverride` 플래그.
- 디버그 패널: 책등 슬라이더(30~70%) + 수동 모드일 때 "책등 자동 감지로
  되돌리기" 버튼. 카메라 프리뷰에 **자홍색 세로선**으로 현재 책등 위치 표시.

### 5-D. 스티칭 품질 투표 — 문제 A 대응 (★ 코드 완료, 실기기 미검증)
책이 캡처 사이 조금씩 흔들려 띠 병합이 어긋나던 문제 대응.
- `_bandOverlap` 0.06 → **0.12** (겹침 2배 — 앵커 잡을 재료·품질투표 줄 확보).
- `_BandSegment`·`_ocrLines`·`_stitchColumn`이 `String` 대신 **`_VisionLine`**
  (텍스트 + centerY)을 다룬다.
- `_stitchColumn`: 앵커(연속 2줄 ≥80% 유사)가 잡히면 그 offset(`delta`)으로
  겹침 구간 줄을 1:1로 짝지어, 각 짝에서 **품질이 높은 사본을 채택**한다.
  품질 = `_lineQuality` = 크롭 경계로부터의 거리(0=경계, 0.5=중앙). 경계에
  걸린 줄은 글자가 잘려 손상되므로 더 안쪽 띠의 사본을 남긴다.
- 앵커를 못 찾으면 기존처럼 무손실 concat 폴백 + 실패 플래그(스낵바 경고).

## 6. 명령 3 핵심 코드 위치 (`scan_screen.dart`)

- `_initCamera()` — 카메라 초기화. 해상도 `ResolutionPreset.high`.
- `_collectCleanBands()` — 손 안 가린·미수집 띠의 첫 연속구간 → `_captureBandFrame`.
- `_captureBandFrame(bandStart, bandEnd)` — 촬영 → 책등 감지 → 좌우 크롭 → OCR
  → `_BandSegment` 저장.
- `_decodeOriented(bytes)` — JPEG 디코딩 + EXIF 회전 픽셀 반영. `package:image`.
- `_detectSpineX(src)` — 책등 가로위치 자동 감지(텍스처 최소 컬럼).
- `_updateSpineX(value)` / `_resetSpineAuto()` — 디버그 슬라이더 수동 보정 / 자동 복귀.
- `_cropEncode(src, top, bottom, left, right)` — 정규화 사각형 크롭 → JPEG 인코딩.
- `_getVisionLines(bytes)` — Vision 응답을 줄 단위 파싱. **줄바꿈은 단어 경계상자
  X/Y 좌표로 직접 판정**(detectedBreak 미사용). 반환: `List<_VisionLine>`.
- `_ocrLines(bytes)` — `_getVisionLines` 래퍼, 비지 않은 `_VisionLine` 목록 반환.
- `_assembleAndSaveBands()` — 좌/우 컬럼 각각 스티칭 → 조립 → 저장.
- `_stitchColumn(columnSegments)` — 겹침 앵커 + 품질 투표로 컬럼 병합. `(merged, failed)`.
- `_lineQuality(line)` — 줄 품질 = 크롭 경계로부터의 거리.
- `_findStitchAnchor` / `_lineSimilar` / `_anchorWeight` / `_levenshtein` — 퍼지 스티칭 보조.
- `_resetBandCollection()` — 띠 상태 초기화.
- 클래스: `_VisionLine(text, centerY)`, `_OcrWord(text, minX, maxX, minY, maxY)`,
  `_BandSegment(bandStart, bandEnd, leftLines, rightLines)`,
  `_StitchAnchor(tailIndex, headIndex)`.
- `scan_camera_view.dart`: `_HandBoxPainter`가 손 박스·추적·하단여백선·띠·**책등선**을
  그림. 디버그 패널에 하단경계 슬라이더 + **책등 슬라이더/자동복귀 버튼**.

### 명령 3 상수 (`_ScanScreenState`)
- `_bandCount = 4` — 띠 개수
- `_bandOverlap = 0.12` — 인접 캡처 겹침 여유(스티칭용, 0.06에서 확대됨)
- `_spineXDefault = 0.5` / `_spineMin = 0.30` / `_spineMax = 0.70` — 책등 기본값·범위
- `_stitchMinRun = 2` / `_stitchSimThreshold = 0.80` / `_stitchWindow = 14` — 스티칭 파라미터

## 7. ★ 다음 세션이 가장 먼저 할 일 — 스티칭 품질투표 실기기 검증

5-D(스티칭 품질 투표)는 **코드와 `flutter analyze`만 통과했고 실기기 검증을 못 했다**
(검증 시점에 기기 연결이 끊겨 있었음). 다음 세션은 이걸 먼저 검증한다.

검증 절차:
1. 기기 연결 확인 → `flutter run -d R3CXC0CMTDD --debug` (10번 참조).
2. 디버그 패널을 켜고 책을 손으로 짚어가며 좌우띠 수집 스캔.
3. 책을 일부러 조금씩 흔들어가며 스캔 — 띠 병합이 어긋나는지 본다.
4. `OCR 결과 전체보기` 또는 adb로 결과 파일 확인:
   - **겹침 구간 같은 구절이 2번 들어가는지(문제 A)** — 줄어들었어야 함.
   - 줄 합쳐짐이 없는지(문제 B는 이미 해결됨).
   - 책등 좌우 분리가 깔끔한지.
5. 결과가 나쁘면 조정 후보: `_bandOverlap`(겹침 크기), `_stitchSimThreshold`,
   `_lineQuality` 기준. 품질 신호로 Vision의 단어 `confidence`를 추가하는 것도
   개선안으로 논의됨(현재는 위치 기반 품질만 씀).

## 8. 명령 3 — 해결 이력 및 남은 논점

기기에서 OCR 결과 파일을 직접 꺼내 확인함
(`adb -s <기기> exec-out run-as com.example.readassi_flutter cat app_flutter/books/<bookId>_original.txt`).

- **문제 B(줄 합쳐짐) — 해결됨.** 5-A 줄 재구성으로 처리. 67번 책 실기기 검증 완료.
- **문제 A(겹침 중복) — 대응 코드 완료, 검증 대기.** 5-D 스티칭 품질 투표.
  책 흔들림으로 병합이 어긋나던 것까지 같이 대응. 7번 참조.
- **카메라 기울기 우려 — 해소됨.** "Y좌표로 줄 묶으면 기울기에 약하지 않나"는
  우려는 5-A가 X리셋(기울기 무관)을 1차 신호로 써서 해결.
- **참고**: 글자 인식 노이즈 자체도 일부 있음. 해상도를 high로 올려 완화함(5-B).

진단 원칙(계속 유효): "Vision의 **위치 정보**(단어 boundingBox)는 믿되, Vision의
**레이아웃 판단**(컬럼·줄바꿈)은 안 믿고 좌표로 직접 한다."

## 9. 기존 파이프라인 (참고)

- 페이지 넘김 감지: 프레임 휘도 64점 샘플링 차분, 안정 1.2초 + 직전 촬영 후 2초.
- 명령 2 OCR: `_captureSinglePage` → `_enqueueOcr` → `_getVisionText`(전체 텍스트 문자열).
  후보 dedup(`_PageCandidate`, `_looksLikeDuplicatePage`).
- 명령 3 조립 페이지는 dedup 없이 원본 파일에 직접 append.
- 분석: `_performAnalysis` → Gemini 통합 분석 → (옵션) Claude 인물/관계 재분석.

## 10. 환경 메모

- 작업 폴더: `C:\Readassi` (Flutter 프로젝트 `C:\Readassi\readassi_flutter`).
- Flutter SDK: `C:\flutter` (PATH에 없음 → `C:\flutter\bin\flutter.bat` 직접 호출).
  채널 stable 3.41.5.
- `.env`: `readassi_flutter/.env` (gitignore 대상). 키: `_kakaoApiKey`,
  `_googleBooksApiKey`, `_googleVisionApiKey`, `_geminiApiKey` — 모두 채워져 있음.
- 안드로이드 실기기: SM S938N. 기기 ID `R3CXC0CMTDD` (`flutter devices`로 확인).
- 빌드/실행: `cd readassi_flutter && C:\flutter\bin\flutter.bat run -d R3CXC0CMTDD --debug`.
  Dart만 바뀌면 Gradle 증분 빌드. 컴파일 점검은
  `C:\flutter\bin\flutter.bat analyze lib/src/screens/scan_screen.dart`.
- `adb`: `C:\Users\남기찬\AppData\Local\Android\Sdk\platform-tools\adb.exe`.
  결과 파일 확인: `adb -s R3CXC0CMTDD exec-out run-as com.example.readassi_flutter cat app_flutter/books/<bookId>_original.txt`.
- 의존성: `image: ^4.8.0` 사용 중(크롭/EXIF/책등감지 축소). `pubspec.yaml`에 이미 있음.
- MediaPipe 손 모델: `readassi_flutter/android/app/src/main/assets/hand_landmarker.task` (있음).

## 11. 핵심 파일 구조

```
readassi_flutter/
  lib/src/
    screens/scan_screen.dart        ← 카메라·촬영·손감지·명령3 좌우띠수집·책등감지·
                                       Vision OCR·줄재구성·스티칭 (가장 큰 파일)
    screens/scan_camera_view.dart   ← 카메라 프리뷰 UI, 디버그 패널(하단경계·책등
                                       슬라이더), _HandBoxPainter 오버레이
    screens/book_detail_screen.dart, page_extractor.dart
    services/hand_detection_service.dart  ← 손 감지 플랫폼 채널 래퍼
    services/claude_service.dart
    app_state.dart
  android/app/src/main/kotlin/com/example/readassi_flutter/
    HandDetector.kt    ← MediaPipe HandLandmarker (VIDEO 모드)
    MainActivity.kt    ← MethodChannel: readassi/hand_detection
  android/app/build.gradle.kts  ← mediapipe tasks-vision, mlkit text-recognition-korean(미사용)
  pubspec.yaml       ← image, camera, http 등
```

## 12. 협업 규칙 (사용자 선호 — 반드시 지킬 것)

- 요청하지 않은 코드 수정/리팩터링 금지. 시킨 것만 수행한다.
- 코드 검토/질문을 받으면 진단·제안만 하고, 실제 수정은 명시적 지시 전까지 보류한다.
- 큰 갈림길(아키텍처 선택 등)은 코드를 쓰기 전에 먼저 물어본다.
- 명령 프롬프트에 "그 외엔 아무것도 하지 마라"가 붙으면 문자 그대로 따른다.
- 작업은 얇게 슬라이스하고 매번 실기기 빌드로 검증한다.

## 13. Git / 셋업

- 명령 1만 `main`에 커밋(`960be9c5`). 명령 2·3은 미커밋 작업본.
- 다른 PC에서: `git pull origin main` → `flutter pub get` → `.env` 있는지 확인.
- 이 `HANDOFF.md`는 커밋하지 않는다 — 파일을 새 세션에 직접 준다.
