# Readassi 인수인계 노트

> 이 파일을 새 Claude Code 세션에 주면 지금까지 맥락을 그대로 이어받는다.
> 작업 폴더 `C:\Readassi`, Flutter 프로젝트 `readassi_flutter/`.
> **최종 갱신: 2026-05-19.**
> 이 `HANDOFF.md`는 커밋하지 않는다 — 파일을 새 세션에 직접 준다.

---

## 1. 프로젝트 개요

- **Readassi**: Flutter 기반 AI 독서 보조 앱. 스마트폰을 책 위에 거치 → 자동 촬영
  → OCR → 등장인물 프로필 / 관계도 / 스토리 요약 / AI 질의응답 생성.
- 리포지토리: `github.com/dttchan411/Readassi` (main 브랜치)
- OCR = Google Vision(클라우드). 통합 분석 = Gemini 2.5 Flash. 페이지 인용 Q&A = Gemini 2.5 Flash.
- Claude(Anthropic) 코드도 존재하나 **API 키가 없어 비활성** 상태(6번 참조).

## 2. 환경

- 작업 폴더 `C:\Readassi`, Flutter 프로젝트 `C:\Readassi\readassi_flutter`.
- Flutter SDK `C:\flutter` (PATH에 없음 → `C:\flutter\bin\flutter.bat` 직접 호출). stable 3.41.5.
- `.env`: `readassi_flutter/.env` (gitignore 대상). 키 4개:
  `_kakaoApiKey`, `_googleBooksApiKey`, `_googleVisionApiKey`, `_geminiApiKey`.
  **`ANTHROPIC_API_KEY`는 없다** — Claude 기능이 전부 꺼지는 원인.
- 안드로이드 실기기: SM S938N, 기기 ID `R3CXC0CMTDD`.
- 빌드/실행: `cd readassi_flutter && C:\flutter\bin\flutter.bat run -d R3CXC0CMTDD --debug`
- 컴파일 점검: `C:\flutter\bin\flutter.bat analyze lib`
- adb: `C:\Users\남기찬\AppData\Local\Android\Sdk\platform-tools\adb.exe`
- 기기 파일 확인:
  `adb -s R3CXC0CMTDD exec-out run-as com.example.readassi_flutter cat app_flutter/books/<파일명>`
- **주의**: 기기 화면이 꺼지면 `flutter run` 연결이 끊긴다("Lost connection to device").
  테스트 중에는 기기 화면을 켜 둘 것.

## 3. 큰 목표 — 손 가림 텍스트 추출 + 정확한 페이지 관리

사용자가 손으로 책을 짚으며 읽을 때 손에 가린 부분도 복원해 한 페이지를 완성하고,
재독·페이지 점프를 정확히 추적한다. 작업은 명령(슬라이스) 단위로 얇게 잘라 매번 실기기 검증.

| 명령 | 내용 | 상태 |
|---|---|---|
| 명령 1 | MediaPipe 손 감지 통합 + 디버그 패널 | 완료 · 커밋 `960be9c5` |
| 명령 2 | 손 미겹침 → 페이지 전체 촬영 → OCR | 완료. 단 아래 4번에서 페이지 저장소로 통합되며 재작성됨 |
| 명령 3 | 좌우분리 가로 띠 수집(손 가림 대응) + 책등 자동감지 + 줄 재구성 + 스티칭 | 완료 · 실기기 동작 확인 |

> 명령 3 세부: 손이 본문을 가리면 손 안 가린 가로 띠만 골라 촬영, 책등 기준 좌·우로
> 크롭해 각각 Vision OCR, 캡처별 세그먼트를 겹침 스티칭으로 병합. 줄바꿈은 Vision의
> detectedBreak가 아니라 단어 경계상자 좌표로 직접 판정(`_getVisionLines`).

## 4. 완성 기능 A — 재독 감지 + 페이지번호 키 저장소 (슬라이스 1~3)

**상태: 구현 완료 · 실기기 검증 완료(2026-05-18).** 모두 `scan_screen.dart`.

기존 페이지넘김 알고리즘은 "직전 페이지"만 비교해, 사용자가 앞 페이지로 되돌아가면
같은 페이지를 또 저장하는 문제가 있었다. 이를 해결:

- **페이지 저장소**: 펼침면 한 장을 `_StoredPage`(좌/우 페이지번호 + 좌/우 본문 +
  상단 지문 + 품질점수)로 보관. 작업용 = `_pageStore`(메모리) ↔ `<bookId>_pages.json`.
- **재독 감지**: 새로 조립된 펼침면의 상단 지문(좌·우 상단 3줄씩)을 **지금까지 저장된
  모든 페이지**와 비교. 유사도 ≥ `_rereadSimThreshold`(0.6)면 재독으로 보고 중복 저장
  안 함. 더 선명하면(품질점수↑) 본문만 교체. (`_commitSpread`)
- **러닝 헤더 자동 제거**: 3개 이상 페이지 상단에 반복되는 줄(책/장 제목)은 지문 비교에서
  제외(`_isRunningHeader` / `_topLineFrequency`). 챕터 제목 때문에 모든 페이지가 유사로
  묶이는 오탐 방지.
- **페이지 번호 추출(`_extractBottomPageNumber`)**: 하단 6줄 중 본문 문단(어절 많은 긴
  줄)과 `N .` 코드 줄번호 줄을 거른 뒤, 남은 짧은 푸터 줄들의 숫자 중 **가장 큰 값**을
  채택. 기대값에 의존하지 않아 페이지 점프(재독)에 강함. 책마다 페이지번호가 `050`처럼
  숫자만 있기도, `228 Chapter`처럼 장 제목과 한 줄에 섞이기도 하는데 둘 다 처리됨.
- **좌·우 번호 보정**: 펼침면의 좌·우 페이지 번호는 연속(left = right−1)이어야 함.
  둘 다 잡혔는데 인접하지 않으면 한쪽이 장·절 번호를 오인식한 것 → 더 큰 값을 실제
  페이지로 보고 보정. 한쪽만 잡히면 ±1 역산, 둘 다 없으면 직전+N 추정("번호 미확정").
- **조기 재독 검사(슬라이스 3)**: 명령 3에서 맨 위 띠(band 0)가 모이면, 4개 띠를 다
  모으기 전에 상단 지문으로 재독을 미리 판정 → 재독이면 나머지 띠 OCR을 건너뜀
  (`_checkEarlyReread` / `_topPrefixFingerprint`). 조기 검사가 놓쳐도 조립 시점
  `_commitSpread`가 다시 거르므로 정확성은 안전.
- **누락 페이지**: 분석 시 `_buildFlatTextFromStore`가 페이지 번호순 평문으로 펼치며
  빈 구간에 `[N~Mp 누락]` 마커 삽입 → Gemini가 누락을 인지.

검증된 동작: 신규 저장, 순차 번호(214→227 등), 점프 번호(222·223), 재독 감지(유사도
0.96~1.00), 조기 재독 감지, 누락 감지, 분석 파이프라인 — 전부 정상.

**튜닝 상수**(`_ScanScreenState`): `_fingerprintLineCount=3`, `_rereadSimThreshold=0.6`,
`_runningHeaderMinPages=3`, `_pageNumberSearchLines=6`, `_pageNumberMaxTokens=6`.

## 5. 완성 기능 B — 페이지 인용 Q&A (슬라이스 A~B)

**상태: 구현 완료 · `flutter analyze` 통과 · 실기기 검증 진행 중(미완).**

목표: "X 인물이 ~한 게 몇 페이지지?" → "37페이지에 나와요" 형태로 **근거 페이지 번호까지**
답하는 Q&A. 기존 Q&A는 요약본만 LLM에 줘서 페이지 정보가 아예 없었음.

- **슬라이스 A — 페이지 본문 영구 보관** (`scan_screen.dart`):
  - `_StoredPage`가 좌/우 페이지 본문을 분리 보관(`leftText`/`rightText`).
  - 분석 시 `_mergePageTextStore`가 페이지 번호를 키로 영구 저장소
    `<bookId>_pagetext.json`(`{"37":"본문", ...}`)에 병합. **분석 후에도 안 지움.**
    같은 페이지를 다시 스캔하면 최신 본문으로 덮어씀.
  - 검증됨: 24쪽 병합 확인.
- **슬라이스 B — Gemini 페이지 인용 Q&A**:
  - 새 파일 `lib/src/services/gemini_service.dart` — `GeminiService.answerBookQuestion`.
    `_pagetext.json`을 페이지 태그(`=== 37쪽 ===`)와 함께 Gemini 2.5 Flash에 전부 보내고,
    "근거 페이지 번호를 함께 답하라"고 지시. 항상 사용자에게 보여줄 한국어 문자열을 반환.
  - `book_detail_screen.dart`의 "질문" 탭이 ClaudeService 대신 GeminiService 사용.
  - 분석을 한 번도 안 거치면 `_pagetext.json`이 비어 "아직 보관된 페이지 본문이 없어요"
    안내가 나옴 — 반드시 스캔 → 분석 → 질문 순서.

## 6. 인물 관계도 / Q&A / Claude 현황

- **인물 관계도**: `book_detail_screen.dart`의 "관계" 탭 `_RelationshipMapView`.
  노드·관계선·라벨·범례·노드선택 필터를 `CustomPaint`로 직접 그림(외부 그래프 라이브러리
  없음). **렌더링은 항상 동작.** 관계 **데이터**는 `_performAnalysis`에서 Gemini 통합
  분석의 `ui_relationships`가 채움. Claude `analyzeCharactersAndRelationships`(재분석
  보강)는 키가 없어 스킵 → 현재 관계 데이터는 Gemini만으로 채워짐.
- **Q&A**: 위 5번처럼 Gemini로 이전 완료. 옛 `ClaudeService.answerBookQuestion`은 이제
  미사용 코드.
- 즉 두 기능 다 "구현은 돼 있었고" Claude 키가 없어 Claude 경로만 꺼져 있던 것.
  Q&A는 Gemini로 옮겨 해결했고, 관계도 보강을 Claude로 살릴지/Gemini로 옮길지는 미정.

## 7. 핵심 코드 위치

- `scan_screen.dart` (가장 큰 파일) — 카메라·촬영·손감지·명령3 띠수집·책등감지·Vision OCR·
  줄재구성·스티칭·**페이지 저장소·재독·번호·누락·페이지본문 병합**.
  - `_commitSpread` — 조립된 펼침면을 저장소에 반영(재독 검사·번호 매기기).
  - `_checkEarlyReread` / `_topPrefixFingerprint` — 슬라이스 3 조기 재독.
  - `_extractBottomPageNumber` — 하단 페이지번호 추출.
  - `_buildFingerprintLines` / `_fingerprintSimilarity` / `_isRunningHeader` — 재독 지문.
  - `_mergePageTextStore` — 영구 페이지본문 저장소 병합.
  - `_buildFlatTextFromStore` — 분석용 평문(누락 마커 포함) 생성.
  - `_persistPageStore` / `_loadPageStore` — 작업용 저장소 디스크 입출력.
  - `_performAnalysis` — Gemini 통합 분석 → DB 저장 → pagetext 병합 → 작업저장소 삭제.
  - 클래스 `_StoredPage`, `_VisionLine`, `_OcrWord`, `_BandSegment`, `_StitchAnchor`.
- `services/gemini_service.dart` — 페이지 인용 Q&A.
- `services/claude_service.dart` — `analyzeCharactersAndRelationships`(관계 보강, 키 없어
  비활성) + `answerBookQuestion`(미사용) + `analyzeScanText`(미사용 추정).
- `screens/book_detail_screen.dart` — 요약/인물/관계/질문 4탭. 관계도·Q&A UI.
- `screens/scan_camera_view.dart` — 카메라 프리뷰, 디버그 패널(하단경계·책등 슬라이더), 오버레이.
- `services/hand_detection_service.dart` — 손 감지 플랫폼 채널 래퍼.
- `android/.../HandDetector.kt` — MediaPipe HandLandmarker(VIDEO 모드).

저장 파일(기기 `app_flutter/books/`):
- `<bookId>_pages.json` — 작업용 페이지 저장소(분석 후 삭제).
- `<bookId>_pagetext.json` — 영구 페이지 본문(Q&A용, 분석 후에도 유지).
- `<bookId>_story_db.json` / `<bookId>_char_db.json` — 분석 내부 DB.

## 8. 미해결 / 다음 작업

1. **★ 손 코너 대기 문제 (최우선, 미해결).** 실사용 테스트 결과, 책 좌측 상단·우측
   상단을 손으로 짚고 페이지를 넘기려 대기하는 사용자가 많음. 그러면 상단/전체에서
   손이 검출돼 OCR이 안 됨. 사용자 1차 아이디어: "손으로 검출된 영역이 일정 시간
   움직이지 않으면 그 손은 텍스트를 가리는 게 아니라 페이지 넘기려 대기 중인 손으로
   간주하고, 그 띠/전체를 OCR한다." 단 반례 — 윗부분을 읽으며 아랫부분을 손으로 가린
   채 가만히 있으면, 가려진 아랫부분이 OCR돼 버림. **이 반례를 어떻게 풀지 미합의.**
   코드 쓰기 전에 사용자와 방향을 먼저 정할 것.
2. **슬라이스 B(페이지 인용 Q&A) 실기기 검증 미완.** 마지막 세션에서 빌드·실행 후
   질문을 보냈고 답변 확인 중에 대화가 끝남. 다음 세션에서 질문→페이지 인용 답변이
   제대로 나오는지 확인부터 할 것.
3. **`GeminiService` HTTP 호출에 타임아웃·로그 없음.** 네트워크가 멈추면 답도 안 오고
   질문 탭 전송 버튼이 계속 비활성으로 멈출 수 있음. 디버그 로그 + 타임아웃 + 실패
   안내를 추가하는 게 좋음(검증 편의에도 도움).
4. **인물 관계도 Claude 보강**: 현재 Claude 키 없어 꺼짐. Claude 키를 넣을지, 보강을
   Gemini로 옮길지, 그냥 Gemini 1차만 쓸지 미정.
5. **정리 후보**: `claude_service.dart`의 `answerBookQuestion`(미사용),
   `screens/page_extractor.dart`(`PageExtractor` — 페이지번호 추출이 `_extractBottomPageNumber`로
   대체되어 더 이상 안 쓰임, 고아 파일). 삭제 여부는 4번 결정과 함께.

## 9. 파일 구조

```
readassi_flutter/
  lib/main.dart
  lib/src/
    app.dart, app_state.dart, theme.dart
    models/        book.dart, mock_books.dart
    screens/       scan_screen.dart            ← 가장 큰 파일(촬영·OCR·페이지저장소)
                   scan_camera_view.dart, book_detail_screen.dart
                   character_profile_screen.dart, page_extractor.dart(고아)
                   home_shell.dart, home_screen.dart, select_book_screen.dart
                   continue_reading_screen.dart, barcode_scan_screen.dart
    services/      gemini_service.dart         ← 페이지 인용 Q&A (신규)
                   claude_service.dart, hand_detection_service.dart
    widgets/       chat_bubble.dart, book_cover.dart, book_progress_bar.dart
  android/app/src/main/kotlin/com/example/readassi_flutter/
                   HandDetector.kt, MainActivity.kt
  .env             ← gitignore. 키 4개(_geminiApiKey 등). ANTHROPIC_API_KEY 없음
```

## 10. Git 상태

- 브랜치 `main`. 최근 커밋: `bff91844 손가림 알고리즘 수정`(슬라이스 1~3 포함, 사용자 커밋).
- **미커밋 작업본** = 페이지 인용 Q&A(슬라이스 A~B):
  - `M scan_screen.dart`, `M book_detail_screen.dart`, `?? services/gemini_service.dart`
- 커밋은 사용자가 직접 한다. 시키지 않으면 커밋하지 말 것.

## 11. 협업 규칙 (사용자 선호 — 반드시 지킬 것)

- 요청하지 않은 코드 수정/리팩터링 금지. 시킨 것만 수행한다.
- 코드 검토/질문을 받으면 진단·제안만 하고, 실제 수정은 명시적 지시 전까지 보류한다.
- 큰 갈림길(아키텍처 선택 등)은 코드를 쓰기 전에 먼저 물어본다.
- 작업은 얇게 슬라이스하고 매 슬라이스마다 실기기 빌드로 검증한다.
- 코드가 수정되면 연결된 실기기로 빌드·실행까지 해서 검증한다.
- `flutter analyze`로 컴파일을 확인하고, 죽은 코드는 남기지 말고 완전히 삭제한다.
