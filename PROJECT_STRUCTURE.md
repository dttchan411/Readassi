# Readassi 구조 및 흐름 정리

## 1. 프로젝트 개요

Readassi는 **책을 읽는 중간 맥락을 잊지 않도록 도와주는 AI 독서 보조 앱**입니다.

현재 저장소 기준으로 실제 구현의 중심은 `readassi_flutter/` 아래의 Flutter 앱입니다.  
핵심 사용 흐름은 아래와 같습니다.

1. 책 바코드를 스캔해 책을 등록한다.
2. 읽던 책을 선택해 페이지를 계속 촬영한다.
3. OCR로 텍스트를 추출한다.
4. AI가 새 텍스트와 기존 분석 결과를 합쳐 요약과 인물 정보를 갱신한다.
5. 사용자는 요약, 인물, 관계, 질문 화면에서 내용을 다시 확인한다.


## 2. 저장소 구조

```text
Readassi/
├─ guidelines/
│  └─ Guidelines.md
├─ readassi_flutter/
│  ├─ lib/
│  │  ├─ main.dart
│  │  └─ src/
│  │     ├─ app.dart
│  │     ├─ app_state.dart
│  │     ├─ theme.dart
│  │     ├─ models/
│  │     ├─ screens/
│  │     ├─ services/
│  │     └─ widgets/
│  ├─ android/
│  ├─ ios/
│  ├─ web/
│  ├─ windows/
│  ├─ macos/
│  ├─ linux/
│  └─ test/
├─ ATTRIBUTIONS.md
├─ README.md
└─ SETUP.md
```

### 중요 폴더만 보면

- `readassi_flutter/`
  - 실제 앱 코드가 있는 메인 프로젝트
- `readassi_flutter/lib/src/models/`
  - 책, 인물, 관계 같은 데이터 구조
- `readassi_flutter/lib/src/screens/`
  - 화면과 사용자 흐름
- `readassi_flutter/lib/src/services/`
  - 외부 AI/API 연동
- `readassi_flutter/lib/src/app_state.dart`
  - 로컬 상태 관리와 저장


## 3. 앱 시작 구조

### 앱이 켜질 때의 흐름

1. `lib/main.dart`
   - Flutter 바인딩 초기화
   - `.env` 로드
   - 앱 실행
2. `lib/src/app.dart`
   - `AppState` 생성
   - `AppStateScope`로 전역 상태 주입
   - `HomeShell` 진입
3. `lib/src/screens/home_shell.dart`
   - 하단 탭 구성
   - `홈`, `분석 기록` 화면 전환


## 4. 화면 구조

### A. 홈 화면

파일: `lib/src/screens/home_screen.dart`

역할:

- 앱의 첫 화면
- 두 가지 주요 행동 제공
  - `새로 책 읽기`
  - `이어 읽기`

이 화면에서 이동하는 곳:

- `BarcodeScanScreen`
- `ContinueReadingScreen`


### B. 바코드 스캔 화면

파일: `lib/src/screens/barcode_scan_screen.dart`

역할:

- 책 바코드를 스캔
- ISBN 추출
- 외부 도서 API로 책 정보 조회
- 새 책을 로컬 상태에 등록

현재 사용하는 외부 조회 순서:

1. Kakao Book Search API
2. Google Books API

가져오는 대표 정보:

- 제목
- 저자
- 표지 이미지 URL
- ISBN
- 출판사
- 출간일


### C. 이어 읽기 화면

파일: `lib/src/screens/continue_reading_screen.dart`

역할:

- 기존에 등록한 책 목록 표시
- 검색 및 정렬
- 선택한 책으로 스캔 이어가기

이 화면에서 이동하는 곳:

- `ScanScreen`


### D. 스캔 화면

파일: `lib/src/screens/scan_screen.dart`

역할:

- 카메라 열기
- 페이지 반복 촬영
- OCR 수행
- 페이지 번호 추정
- 새 텍스트를 기존 분석 결과에 통합

이 앱의 핵심 로직이 가장 많이 들어 있는 화면입니다.


### E. 책 상세 화면

파일: `lib/src/screens/book_detail_screen.dart`

역할:

- 분석된 독서 결과를 사용자에게 보여주는 화면

탭 구성:

1. `요약`
2. `인물`
3. `관계`
4. `질문`


### F. 분석 기록 화면

파일: `lib/src/screens/select_book_screen.dart`

역할:

- 이전에 분석한 책 목록 표시
- 책 상세 화면 다시 열기
- 저장된 책 삭제


## 5. 사용자 흐름

### 흐름 1. 새 책 등록

1. 사용자가 홈 화면에 들어간다.
2. `새로 책 읽기`를 누른다.
3. 바코드 스캐너가 열린다.
4. ISBN이 인식된다.
5. 앱이 Kakao Books를 먼저 조회한다.
6. 실패하면 Google Books를 조회한다.
7. 책 메타데이터를 바탕으로 새 `Book`을 만든다.
8. 이후 사용자는 이어 읽기 흐름으로 진입할 수 있다.


### 흐름 2. 읽던 책 계속 분석

1. 사용자가 홈에서 `이어 읽기`를 누른다.
2. 저장된 책 하나를 선택한다.
3. `ScanScreen`이 열린다.
4. 사용자가 촬영을 시작한다.
5. 앱이 일정 간격으로 페이지를 촬영한다.
6. 촬영 이미지를 Google Vision OCR로 보낸다.
7. 추출된 텍스트를 임시 원문 파일에 누적한다.
8. OCR 텍스트에서 페이지 번호를 추정한다.
9. 사용자가 업데이트를 누른다.
10. 앱이 아래 데이터를 함께 읽는다.
    - 새 OCR 원문
    - 기존 story DB
    - 기존 character DB
11. 앱이 이 데이터를 Gemini로 보낸다.
12. Gemini가 아래 결과를 돌려준다.
    - 내부 story DB
    - 내부 character DB
    - UI용 요약문
    - UI용 인물 목록
13. 앱이 내부 JSON 파일을 저장한다.
14. 앱이 `Book`의 요약과 인물 정보를 갱신한다.
15. 임시 OCR 원문 파일을 삭제한다.
16. `BookDetailScreen`으로 이동한다.


### 흐름 3. 책에 대해 질문하기

1. 사용자가 책 상세 화면을 연다.
2. `질문` 탭으로 이동한다.
3. 질문을 입력한다.
4. 앱이 저장된 책 요약과 인물 정보를 Claude에 전달한다.
5. Claude가 한국어 답변을 반환한다.
6. 앱이 채팅 형태로 답변을 보여준다.


## 6. 데이터 모델

기준 파일: `lib/src/models/book.dart`

### Book

대표 필드:

- `id`
- `title`
- `author`
- `coverUrl`
- `summary`
- `characters`
- `relationships`
- `keywords`
- `currentPage`
- `totalPages`
- `progress`
- `isbn`
- `publisher`
- `publishedDate`
- `description`

### Character

- `id`
- `name`
- `role`
- `description`
- `imageUrl`

### Relationship

- `source`
- `target`
- `label`


## 7. 상태 관리와 저장 방식

기준 파일: `lib/src/app_state.dart`

이 프로젝트는 `AppState`를 중심으로 앱 상태를 관리합니다.

주요 책임:

- 저장된 책 불러오기
- 새 책 등록
- 요약 갱신
- 인물 정보 갱신
- 현재 페이지 및 진행률 갱신
- 책 삭제
- 로컬 저장소에 다시 저장

현재 저장 방식:

- `SharedPreferences`

저장 내용:

- `Book` 목록 전체를 JSON으로 직렬화해서 저장

초기 동작:

- 저장된 데이터가 없으면 `mockBooks`로 시작


## 8. 분석 중 생성되는 로컬 파일

기준 파일: `lib/src/screens/scan_screen.dart`

책별 분석 파일은 앱 문서 디렉터리 아래 `books/` 폴더에 저장됩니다.

현재 용도는 아래와 같습니다.

- `{bookId}_original.txt`
  - OCR로 뽑은 원문 임시 파일
- `{bookId}_story_db.json`
  - 다음 분석 때 참고할 내부 줄거리 데이터
- `{bookId}_char_db.json`
  - 다음 분석 때 참고할 내부 인물 데이터

중요한 점:

- 분석이 성공하면 원문 임시 파일은 삭제됩니다.


## 9. 외부 서비스 의존성

### 도서 메타데이터 조회

- Kakao Book Search API
- Google Books API

용도:

- 제목
- 저자
- 표지
- 출판사
- 출간 정보 조회


### OCR

- Google Vision API

용도:

- 촬영 이미지에서 텍스트 추출


### 독서 내용 통합 분석

- Gemini API

용도:

- 새 OCR 텍스트와 기존 내부 데이터를 통합
- 사용자용 요약 생성
- 사용자용 인물 목록 생성
- 내부용 story/character 메모리 유지


### 책 기반 질문 응답

- Claude API

용도:

- 저장된 책 정보를 바탕으로 사용자의 질문에 답변


## 10. 중요한 소스 파일

### 앱 진입 및 상태

- `lib/main.dart`
- `lib/src/app.dart`
- `lib/src/app_state.dart`

### 모델

- `lib/src/models/book.dart`
- `lib/src/models/mock_books.dart`

### 주요 화면

- `lib/src/screens/home_shell.dart`
- `lib/src/screens/home_screen.dart`
- `lib/src/screens/barcode_scan_screen.dart`
- `lib/src/screens/continue_reading_screen.dart`
- `lib/src/screens/scan_screen.dart`
- `lib/src/screens/book_detail_screen.dart`
- `lib/src/screens/select_book_screen.dart`

### 보조 로직

- `lib/src/screens/page_extractor.dart`
- `lib/src/services/claude_service.dart`

### 공통 UI

- `lib/src/widgets/book_cover.dart`
- `lib/src/widgets/book_progress_bar.dart`
- `lib/src/widgets/chat_bubble.dart`


## 11. 지금 제품의 성격

이 앱은 단순한 책 보관 앱이라기보다 아래 쪽에 더 가깝습니다.

- AI 독서 기록 도우미
- 읽던 책 맥락 유지 도구
- 종이책 페이지 스캔 기반 독서 보조 시스템

코드에서 가장 선명하게 보이는 제품 방향은 다음입니다.

> 사용자가 책을 읽는 도중 줄거리, 등장인물, 진행 상황을 잊지 않도록 돕는다.


## 12. 현재 보이는 한계와 정리 포인트

### 문서와 실제 코드의 차이

- 기존 루트 README는 현재 저장소 상태와 잘 맞지 않습니다.
- 현재 구현 중심은 Flutter입니다.

### 일부 데이터 연결 미완성

- 외부 API에서 받아온 설명 같은 필드가 UI에 충분히 연결되지 않은 구간이 있습니다.

### 삭제 로직 정리 필요

- 일부 삭제 로직은 예전 파일명 기준 흔적이 남아 있어 현재 JSON 기반 구조와 맞지 않을 수 있습니다.

### 관계도 화면이 고정형

- 관계 탭은 현재 임의 인물 수를 일반화한 그래프가 아니라, 소수 인물 기준의 고정 레이아웃에 가깝습니다.

### 외부 API 의존도 높음

- `.env` 설정이 빠지면 핵심 기능 대부분이 제한됩니다.

### 테스트는 아직 얕은 편

- `test/` 폴더는 있지만, 실제 핵심 플로우는 수동 검증 비중이 큰 상태로 보입니다.


## 13. 다음으로 있으면 좋은 문서

이 저장소를 계속 키운다면 아래 문서가 있으면 좋아집니다.

1. `SETUP.md`
   - Flutter 설치, `.env`, 실행 방법
2. `ROADMAP.md`
   - 우선순위와 다음 작업
3. `API_KEYS.md`
   - 어떤 키가 왜 필요한지
4. `ARCHITECTURE.md`
   - 더 자세한 기술 설계


## 14. 한 문단 요약

Readassi는 사용자가 종이책을 읽는 동안 책을 등록하고, 페이지를 촬영해 OCR로 텍스트를 모으고, AI로 요약과 인물 정보를 누적 갱신하며, 나중에 책의 맥락을 다시 빠르게 회복할 수 있도록 돕는 Flutter 기반 독서 보조 앱입니다.
