# Readassi — 인수인계 문서 (HANDOFF)

> 새 대화창을 시작할 때 이 파일을 먼저 읽어 현재 상태를 파악하세요.
> 이 파일은 **커밋하지 않습니다**(새 세션에 직접 전달용).
> 최종 갱신: 2026-05-21

---

## 1. 프로젝트 개요

**Readassi** — 종이책을 카메라로 스캔해 OCR → AI 분석(요약·등장인물·관계도)하고,
책 내용에 대해 Q&A를 할 수 있는 Flutter 독서 보조 앱.

- 경로: `C:\Readassi\readassi_flutter`
- Flutter: `C:\flutter\bin\flutter.bat`
- 명령 실행 위치: `cd /c/Readassi/readassi_flutter` (pubspec.yaml 위치)
- 테스트 단말기: `R3CXC0CMTDD` (Samsung SM-S938N)
- 빌드: **디버그 모드로 실행**할 것. 릴리즈(`--release`)는 R8 minify 단계에서
  `javax.lang.model.*` 누락(autovalue/ML Kit 전이 의존성)으로 실패함 → 별도 미해결.

---

## 2. 작업 규칙 (중요)

- **커밋은 사용자가 직접 함.** 요청 없이는 `git commit` 하지 말 것.
- **HANDOFF.md는 커밋 안 함.** 사용자가 명시적으로 요청할 때만 갱신.
- API 키는 모두 `.env`에 보관(`.gitignore`의 46번째 줄에 `.env` 등록됨).
  채팅에 키를 노출하지 말 것.
- Auto 모드: 막힘 없이 진행, 라우틴한 결정은 직접 판단.

### `.env` 키 목록 (값은 비공개)
```
_kakaoApiKey         # 카카오 도서 검색
_googleBooksApiKey   # Google Books
_googleVisionApiKey  # Google Vision OCR (클라우드)
_geminiApiKey        # Gemini 2.5 Flash (통합 분석 + Q&A)
ANTHROPIC_API_KEY    # Claude Sonnet 4.6 (관계도 SVG 생성)
ANTHROPIC_MODEL      # = claude-sonnet-4-6
```

---

## 3. 기술 스택

| 영역 | 사용 기술 |
|---|---|
| 프레임워크 | Flutter / Dart (SDK ^3.11.1) |
| 카메라 | `camera` 0.11 — YUV420 이미지 스트림 |
| OCR | Google Vision API (클라우드, DOCUMENT_TEXT_DETECTION) |
| AI 분석·Q&A | Gemini 2.5 Flash (`gemini_service.dart`) |
| 관계도 SVG | Claude Sonnet 4.6 (`claude_service.dart`) |
| 손 인식 | MediaPipe Hand (네이티브 플러그인, `hand_detection_service.dart`) |
| 책 테두리 검출 | `opencv_dart` 2.2.1+4 (`dartcv4`) — 고전 CV |
| 데모 대시보드 | 순수 `dart:io` HttpServer + WebSocketTransformer |
| SVG 렌더 | `flutter_svg` |
| 저장 | `shared_preferences`(책 메타) + 기기 JSON 파일 |

---

## 4. 파일 구조 (`lib/`)

```
lib/
  main.dart                         앱 진입점, dotenv 로드
  src/
    app.dart                        앱 루트 위젯
    app_state.dart                  ChangeNotifier 전역 상태(책 목록/분석 결과)
    theme.dart
    models/
      book.dart                     Book, Character, ChatMessage 등 모델
      mock_books.dart
    screens/
      home_shell.dart / home_screen.dart
      select_book_screen.dart
      barcode_scan_screen.dart      ISBN 바코드 스캔
      continue_reading_screen.dart
      scan_screen.dart              ★ 페이지 스캔/OCR/캡처 핵심 로직
      scan_camera_view.dart         ★ 스캔 화면 UI(카메라 프리뷰+오버레이)
      book_detail_screen.dart       ★ 책 상세(요약/등장인물/관계도/Q&A)
      character_profile_screen.dart 등장인물 프로필 상세
      page_extractor.dart
    services/
      gemini_service.dart           통합 분석 + Q&A (재시도/타임아웃 포함)
      claude_service.dart           관계도 SVG 생성
      hand_detection_service.dart   MediaPipe 손 인식 브리지
      book_box_detection_service.dart  OpenCV 책 테두리 박스 1회 검출 (손 마스킹)
      demo_dashboard_service.dart   ★ NEW: 8셀 실시간 데모 웹 대시보드
    widgets/
      book_cover.dart / chat_bubble.dart / book_progress_bar.dart
```

### 기기 저장 파일 (per book, `getApplicationDocumentsDirectory()`)
- `<bookId>_pages.json`    — 조립된 펼침면(페이지) 저장소
- `<bookId>_pagetext.json` — 누적 본문 텍스트
- `<bookId>_chat.json`     — Q&A 대화 기록(앱 재시작 후에도 유지)
- `<bookId>_relmap.svg`    — Claude가 생성한 관계도 SVG

---

## 5. 완료된 주요 기능

### 5.1 책 상세 화면 (`book_detail_screen.dart`)
- 상단 헤더 컴팩트화(작은 표지 + 제목).
- 요약: 책 전체를 다루며 가독성 개선.
- 등장인물 카드: 중요도(`importance`) 내림차순 정렬, 중요도 ≤ 1인 단역은
  `_MinorCharactersSection`으로 접어 표시. 프로필 항목 = 성격 / 목표·동기 / 첫 등장 페이지.
- 관계도: Claude 생성 SVG를 `_RelationshipSvgView`에서 `SvgPicture.string` +
  `InteractiveViewer`로 렌더.
- Q&A: "생각중..." 애니메이션 버블(`_ThinkingBubble`), 대화 영구 저장.
- **Q&A 카드 높이**: `(mediaHeight - 280).clamp(380.0, 1200.0)` — 더 길어졌음.

### 5.2 AI 분석 (`scan_screen.dart` + `gemini_service.dart`)
- Gemini 한 번 호출로 요약·등장인물·관계 통합 분석(`thinkingBudget: 0`).
- 내부 story/character DB 제거 → 분석 속도 개선.
- `ui_characters`에 importance/personality/motivation/first_page 포함.
- 관계도 SVG는 분석 후 백그라운드로 별도 생성(`_generateRelationshipSvg`).
- 저장된 텍스트로 재분석 가능(재스캔 불필요).
- **마지막 읽은 페이지**: 분석 기록에는 사용자가 진짜 읽은 마지막 페이지를
  보존(현재 인식 페이지가 아님).

### 5.3 등장인물 추출 정합성 (`app_state.dart`)
- `updateBookCharacters`: 들어온 목록 기준으로 **재구축**(옛 항목 잔존/중복 방지).
- 기계 키워드 필터로 오검출 제거.
- 주인공 보존 안전망, 중요도 정렬(동률 시 주인공 우선).

### 5.4 페이지 스캔 / OCR 파이프라인 (`scan_screen.dart`) — 가장 복잡
핵심 아이디어: **펼침면을 8칸(4행 × 2열)으로 나눠, 손이 안 가린 칸만 모아 한 페이지 조립.**

- **책 박스 검출**: 촬영 시작 시 사진 1장 찍어 `BookBoxDetectionService.detect()`
  (OpenCV: imread → resize → blur → Canny → dilate → **가로 close(책등 메움)** →
  findContours → 같은 행·인접 박스 병합 → 최대 박스. 세로 비율 < 0.95면 단일 페이지로
  보고 reject)로 정규화 `Rect` 1회 검출. `_bookBox`에 저장.
- **손 마스킹**: 박스 검출 직전 손이 잡혀 있으면 `detectWithHandMask`로 손 영역
  엣지를 통째로 0으로 지움. (`cv.inpaint` 심볼이 opencv_dart 안드로이드 빌드에
  빠져 있어 인페인팅 대신 **엣지 제거** 방식으로 우회 — 12px 마진으로 반그림자까지 컷.)
- **모든 띠/칸은 책 박스 기준 상대 좌표** (프레임 기준 아님 — 우측 손이 좌측 페이지
  검출을 막던 근본 버그 해결).
- **8칸 수집**: `_cellLines` = `List<List<_VisionLine>?>`(길이 8, idx = row*2 + col).
  손이 안 가린 깨끗한 칸만 캡처에서 수확. 좌(col 0)/우(col 1) 칸 독립.
- **손 게이트**: MediaPipe 손이 본문 영역(`_innerTextRegion`, 박스 10% 인셋)을
  `_handOverlapThreshold` 이상 덮으면 캡처 보류. 모서리/여백의 손은 무시.
  손 래치(추적 유지)로 검출이 끊겨도 잠시 "손 있음" 유지.
- **책등(spine)**: 좌우 페이지 분리 세로선 `_spineX`. 자동 감지 + 디버그 슬라이더 수동 보정.
- **재독/누락 감지**: 상단 지문(`_buildFingerprintLines`)으로 같은 페이지 재촬영
  /페이지 넘어감 판정. 재독이면 OCR 비용 절감 위해 stage-1에서 조기 return.
- **스티칭**: 인접 캡처 겹침 앵커(`_bandOverlap`, `_stitchMinRun`, 퍼지 유사도)로 조립.
- **모션 트리거**: 손이 박스 밖에 있을 때 stable 1.2s + motion-end 트리거로 전체 OCR 발사.
- **배치 OCR**: 8셀 중 OCR 대기 칸은 `Future.wait`로 동시 발사 → 직렬 4건 → 1건 지연.
- 캡처 상태: `_CaptureStatus`(idle / capturing / pageChecking / handOverlap 등).

### 5.5 페이지 번호 결정 트리 (`scan_screen.dart`)
하단에서 추출한 페이지 후보 개수 N에 따라 동작:
- **N == 0**: 앵커 폴백(`expectedL`, `expectedR`).
- **N == 1**: 앵커 근사(`_pageAnchorTolerance = 3`) 검사 → 통과 시 사용 + 페어 유도, 아니면 폴백.
- **N == 2**: 페어 검사(연속 + 패리티) 통과면 사용. 한 쪽이 앵커 근사면 + 페어 유도. 아니면 폴백.
- **N >= 3**: `_findBestConsecutivePair`로 연속 2개 우선 채택. 실패 시 폴백.
- 패리티 학습: 5연속 매치 후 lock(`_parityLockMinVotes = 5`).
- 본문(>6 토큰)·코드 라인번호 등은 후보에서 제외.

### 5.6 스캔 화면 UI (`scan_camera_view.dart`)
- 카메라 프리뷰 위에 `_BookBoxPainter`: 책 박스 + 8칸 격자(가로 4분할선 + 가운데
  세로 분할선). 디버그 모드에서 칸별 음영(수집=초록, 손가림=빨강).
- `_HandBoxPainter`(디버그 전용): 손 박스(초록), 추적 유지 박스(주황), 책등 세로선.
- 디버그 패널: 상태/손 감지/8칸 수집 현황/최근 OCR/책등 슬라이더.
- **디버그 패널 드래그 가능**: `_DebugPanelPositioner`(Transform.translate + GestureDetector).
- 헤더: 현재 인식 페이지 + 마지막 읽은 페이지 + 중복 페이지 표시(페이지 번호 포함).
- 가로 모드 고정: `SystemChrome.setPreferredOrientations` + `lockCaptureOrientation(landscapeLeft)`.

### 5.7 손 추적 (`hand_detection_service.dart`)
- **항상 ON**: 카메라가 켜져 있으면 촬영 시작/중지와 무관하게 손 추적.
  `_startAutoCapture`는 손 결과 필드(`_handResult`, `_handResultAt`, 래치)를 **건드리지 않음**.
- **추적 throttle**: 200ms (이전 700ms에서 단축 — 추적 끊김 체감 개선).
- 손 외곽 정밀화는 보류(현재 박스 단위로 충분).

### 5.8 데모 대시보드 (`demo_dashboard_service.dart`) — NEW
졸업작품 데모용 — 폰에서 캡처되는 8셀 OCR 결과를 노트북 브라우저로 실시간 표시.

- **싱글톤**: `scan_screen.dart`에서 `static final DemoDashboardService _dashboard = ...`
  로 보유 → 화면 이동/State dispose에도 서버 살아남음.
- **포트 8080**: `HttpServer.bind(InternetAddress.anyIPv4, 8080)`.
- **엔드포인트 3개**:
  - `/` — 8셀 그리드 HTML(JS로 WS 연결 + 클릭 토글).
  - `/cell/{idx}.jpg` — 셀 이미지 바이너리.
  - `/ws` — `WebSocketTransformer.upgrade(request)`로 업그레이드, 갱신 시그널.
- **셀 상태**: `pushImage(idx, bytes)` 호출 시 텍스트 초기화, `pushText(idx, text)`
  호출 시 **이미지는 유지**(둘 다 있으면 클릭으로 토글 — 노랑 테두리=이미지만,
  초록=둘 다, 파랑=텍스트 보기 중).
- **세션 시작 시에만 reset**: `_startAutoCapture`에서 `_dashboard.reset()`.
  `_resetBandCollection()`에서는 호출 안 함(OCR 후 셀이 비는 버그 해결).
- **URL 표시**: 사설 LAN(`192.168.x` / `10.x` / `172.16-31.x`)을 셀룰러 NAT(`192.0.0.x`)
  보다 우선 — 노트북에서 접속 가능한 주소 자동 선택.
- **재독 시도 셀 이미지 푸시**(이번 세션 마지막 작업): 재독 검출로 stage-1 조기 return
  하는 경우에도 셀 1~7의 깨끗한 부분 이미지를 대시보드에 푸시 → 시각화 끊김 방지.
  OCR은 비용이라 생략 유지(추가 Vision API 호출 0건).

---

## 6. 이번 세션에서 완료된 작업

순서대로:

1. **디버그 패널 드래그 가능** (`scan_camera_view.dart` `_DebugPanelPositioner`).
2. **헤더 정보 확장**: 현재 인식 페이지 + 마지막 읽은 페이지 + 중복 표시(페이지 번호).
3. **손 외곽선 정밀화는 보류** — 박스 단위로 진행.
4. **손 항상 추적**: 카메라 켜지면 손 추적 시작(촬영 시작 게이트 제거).
   `_startAutoCapture`에서 손 상태 필드 초기화 코드 제거.
5. **손 추적 throttle 700ms → 200ms**.
6. **3초 손 미검출 시 박스 검출**: 손 안 잡힘 → 손 없는 상태로 박스 검출.
7. **책 박스 검출 손 마스킹**: `BookBoxDetectionService.detectWithHandMask` 추가.
   처음 흰색 fill / 평균색 fill 모두 새 엣지를 만들어 실패 → **엣지 제거** 방식으로 전환.
   (`cv.inpaint`는 안드로이드 빌드에서 누락 — 사용 불가.)
8. **Q&A 카드 높이 확장**: `(mediaHeight - 280).clamp(380.0, 1200.0)`.
9. **데모 대시보드 서버 구현** (`demo_dashboard_service.dart`):
   - 순수 dart:io HTTP+WS, 외부 패키지 0.
   - URL은 디버그 콘솔에 출력 + 디버그 패널에 표시.
   - 셀 클릭 토글(이미지 ↔ 텍스트).
   - 세션 시작 시에만 reset(OCR 끝나면 셀이 비는 버그 fix).
   - 사설 LAN 우선 URL 선택.
   - 화면 이동에도 살아남도록 정적 싱글톤.
10. **페이지 번호 결정 트리**: 후보 개수별 분기(`_extractBottomPageCandidates`,
    `_decidePageNumbers`). 본문 숫자(예: "87")가 페이지 번호(40-41)를 덮어쓰던 버그 fix.
    `_findBestConsecutivePair`로 연속 페어 우선.
11. **재독 시 셀 이미지 푸시**(가장 최근): 재독 stage-1 조기 return 전에 셀 1~7 이미지를
    대시보드에 푸시. Vision API 추가 호출 없음.

---

## 7. 알려진 이슈 / 다음 작업 후보

- **릴리즈 빌드 실패**: `flutter run --release`가 R8 minify에서
  `javax.lang.model.SourceVersion` 등 누락으로 실패.
  → `android/app/proguard-rules.pro`에 keep 규칙 추가 또는 minify 비활성화 필요.
  현재는 `--debug`로 실행 중.
- `cv.inpaint` 부재: opencv_dart 안드로이드 prebuilt에 photo 모듈 inpaint 심볼이
  빠져 있음. 현재는 엣지 제거로 우회 — 시각적 인페인팅이 꼭 필요하면 다른 경로 필요.
- 페이지 번호 결정 트리는 동작 확인됨 — 추가 케이스 발견 시 `_decidePageNumbers` 보강.
- 디버그 패널이 가끔 페이지 인식 안 될 때 OCR 텍스트 표시 — 의도된 동작.

---

## 8. 자주 쓰는 명령

```bash
cd /c/Readassi/readassi_flutter
/c/flutter/bin/flutter.bat analyze lib
/c/flutter/bin/flutter.bat run -d R3CXC0CMTDD --debug
```

데모 대시보드 접속:
- 폰과 노트북이 같은 Wi-Fi에 연결돼야 함.
- 앱 디버그 콘솔/디버그 패널에 표시되는 URL(예: `http://192.168.x.x:8080/`)을 노트북 브라우저로 접속.
- 8셀 그리드가 실시간으로 갱신됨. 셀 클릭 시 이미지 ↔ 텍스트 토글.
