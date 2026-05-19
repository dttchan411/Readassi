# Readassi — 인수인계 문서 (HANDOFF)

> 새 대화창을 시작할 때 이 파일을 먼저 읽어 현재 상태를 파악하세요.
> 이 파일은 **커밋하지 않습니다**(새 세션에 직접 전달용).
> 최종 갱신: 2026-05-19

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
- **HANDOFF.md는 커밋 안 함.**
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
| OCR | Google Vision API (클라우드) |
| AI 분석·Q&A | Gemini 2.5 Flash (`gemini_service.dart`) |
| 관계도 SVG | Claude Sonnet 4.6 (`claude_service.dart`) |
| 손 인식 | MediaPipe Hand (네이티브, `hand_detection_service.dart`) |
| 책 테두리 검출 | `opencv_dart` 2.2.1 (`dartcv4`) — 고전 CV |
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
      book_box_detection_service.dart  OpenCV 책 테두리 박스 1회 검출
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
  ("등장 작품", "관계 힌트" 항목은 제거됨.)
- 관계도: 기존 CustomPaint 그래프(~720줄) 제거, Claude 생성 SVG를
  `_RelationshipSvgView`에서 `SvgPicture.string` + `InteractiveViewer`로 렌더.
- Q&A: "생각중..." 애니메이션 버블(`_ThinkingBubble`), 대화 영구 저장.

### 5.2 AI 분석 (`scan_screen.dart` + `gemini_service.dart`)
- Gemini 한 번 호출로 요약·등장인물·관계 통합 분석(`thinkingBudget: 0`).
- 내부 story/character DB 제거 → 분석 속도 대폭 개선(기존 1m30s에서 단축).
- `ui_characters`에 importance/personality/motivation/first_page 포함.
- 관계도 SVG는 분석 후 백그라운드로 별도 생성(`_generateRelationshipSvg`).
- 저장된 텍스트로 재분석 가능(재스캔 불필요).

### 5.3 등장인물 추출 정합성 (`app_state.dart`)
- `updateBookCharacters`: 들어온 목록 기준으로 **재구축**(옛 항목 잔존/중복 방지).
- 기계 키워드 필터("컴퓨터" 등)로 오검출 제거.
- 주인공 보존 안전망, 중요도 정렬(동률 시 주인공 우선).

### 5.4 페이지 스캔 / OCR 파이프라인 (`scan_screen.dart`) — 가장 복잡
핵심 아이디어: **펼침면을 8칸(4행 × 2열)으로 나눠, 손이 안 가린 칸만 모아 한 페이지 조립.**

- **책 박스 검출**: 촬영 시작 시 사진 1장 찍어 `BookBoxDetectionService.detect()`
  (OpenCV: imread→resize→blur→Canny→dilate→findContours→최대 윤곽 박스)로
  정규화 `Rect` 1회 검출. `_bookBox`에 저장.
- **모든 띠/칸은 책 박스 기준 상대 좌표** (프레임 전체 기준 아님 — 우측 손이
  좌측 페이지 검출을 막던 버그의 근본 원인 해결).
- **8칸 수집**: `_cellLines` = `List<List<_VisionLine>?>`(길이 8, idx = row*2 + col).
  손이 안 가린 깨끗한 칸만 캡처에서 수확. 좌(col 0)/우(col 1) 칸 독립.
- **손 게이트**: MediaPipe 손이 본문 영역(`_textRegionInset` 만큼 안쪽)을
  `_handOverlapThreshold` 이상 덮으면 캡처 보류. 모서리/여백의 손은 무시.
  손 래치(추적 유지)로 검출이 끊겨도 잠시 "손 있음" 유지.
- **책등(spine)**: 좌우 페이지 분리 세로선 `_spineX`. 자동 감지 + 디버그 슬라이더 수동 보정.
- **재독/누락 감지**: 상단 지문(`_buildFingerprintLines`, 좌상단 우선 → 우상단 폴백)으로
  같은 페이지 재촬영/페이지 넘어감을 판정.
- **스티칭**: 인접 캡처 겹침 앵커(`_bandOverlap`, `_stitchMinRun`, 퍼지 유사도)로 조립.
- 캡처 상태: `_CaptureStatus`(idle / ... / pageChecking "페이지 검사중" 등).

### 5.5 스캔 화면 UI (`scan_camera_view.dart`)
- 카메라 프리뷰 위에 `_BookBoxPainter`: 책 박스 + 8칸 격자(가로 4분할선 +
  가운데 세로 분할선). 디버그 모드에서 칸별 음영(수집=초록, 손가림=빨강).
- `_HandBoxPainter`(디버그 전용): 손 박스(초록), 추적 유지 박스(주황), 책등 세로선.
- 디버그 패널: 상태/손 감지/8칸 수집 현황(행별 `● 수집 / ■ 손가림 / □ 대기`)/
  최근 OCR/책등 슬라이더.

---

## 6. 최근 작업 (이번 세션에서 완료)

"띠 오버레이 죽었으니 치우고 8칸 디버그 표시를 박스 기준으로 옮겨줘" 요청 처리:

- `scan_camera_view.dart`:
  - `bandCount`/`bandCoverage`/`bandCollected` 파라미터 제거 →
    `cellCoverage`/`cellCollected`(길이 8 `List<bool>`)로 교체.
  - `_BookBoxPainter`가 8칸 음영 + 가운데 세로 분할선까지 그림(박스 기준).
  - `_HandBoxPainter`에서 프레임 기준 가로 띠 그리기 코드 전부 제거.
  - 디버그 패널: 4-띠 표시 → 8칸(행별 좌|우) 표시로 교체.
- `scan_screen.dart`:
  - `ScanCameraView` 호출을 `cellCoverage: _cellCoverage()`,
    `cellCollected: _cellCollectedView()`로 변경.
  - `_cellCollectedView()` 헬퍼 추가, 미사용 `_bandCoverage()`/
    `_bandCollectedView()` 제거.
- `flutter analyze lib` → **No issues found.**

---

## 7. 알려진 이슈 / 다음 작업 후보

- **릴리즈 빌드 실패**: `flutter run --release`가 R8 minify에서
  `javax.lang.model.SourceVersion` 등 누락으로 실패.
  → `android/app/proguard-rules.pro`에 keep 규칙 추가 또는 minify 비활성화 필요.
  현재는 `--debug`로 실행 중.
- 분석 속도는 개선됐으나 추가 최적화 여지 있음.
- 8칸 수집 파이프라인은 사용자 확인 "잘 작동" — 안정적.

---

## 8. 자주 쓰는 명령

```bash
cd /c/Readassi/readassi_flutter
/c/flutter/bin/flutter.bat analyze lib
/c/flutter/bin/flutter.bat run -d R3CXC0CMTDD --debug
```
