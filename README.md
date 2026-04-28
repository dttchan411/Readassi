# Readassi

Readassi는 **책을 읽는 흐름을 놓치지 않도록 돕는 AI 독서 보조 앱**입니다.

현재 이 저장소에서 실제 구현의 중심은 `readassi_flutter/` Flutter 프로젝트입니다.  
사용자는 책을 등록하고, 페이지를 스캔하고, OCR과 AI 분석을 통해 줄거리와 등장인물 정보를 누적해서 볼 수 있습니다.


## 주요 기능

- 책 바코드 스캔으로 새 책 등록
- ISBN 기반 도서 정보 조회
- 읽던 책 선택 후 페이지 연속 스캔
- Google Vision OCR로 텍스트 추출
- Gemini 기반 줄거리/인물 정보 통합 분석
- 책 상세 화면에서 요약, 인물, 관계, 질문 확인
- Claude 기반 책 내용 질문 응답


## 현재 구조

이 저장소의 핵심 디렉터리는 아래와 같습니다.

```text
Readassi/
├─ guidelines/
├─ readassi_flutter/
├─ ATTRIBUTIONS.md
├─ README.md
├─ PROJECT_STRUCTURE.md
└─ SETUP.md
```

실제 앱 코드:

- [readassi_flutter](C:\WithAgent\Readassi\readassi_flutter)

구조/흐름 문서:

- [PROJECT_STRUCTURE.md](C:\WithAgent\Readassi\PROJECT_STRUCTURE.md)

실행/환경설정 문서:

- [SETUP.md](C:\WithAgent\Readassi\SETUP.md)


## 사용자 흐름 요약

### 1. 새 책 등록

1. 홈 화면에서 `새로 책 읽기` 선택
2. 바코드 스캔
3. ISBN 기반으로 책 정보 조회
4. 책 등록 완료

### 2. 읽던 책 이어서 분석

1. 홈 화면에서 `이어 읽기` 선택
2. 기존 책 선택
3. 페이지 촬영 시작
4. OCR로 텍스트 수집
5. AI 분석으로 요약/인물 정보 갱신
6. 책 상세 화면으로 이동

### 3. 분석 결과 확인

책 상세 화면에서 아래 탭을 확인할 수 있습니다.

- 요약
- 인물
- 관계
- 질문


## 현재 구현 기준 핵심 기술

- Flutter
- camera
- mobile_scanner
- Google Vision API
- Google Books API
- Kakao Book Search API
- Gemini API
- Claude API
- SharedPreferences


## 현재 상태

이 프로젝트는 완성형 서비스라기보다 **핵심 플로우를 실험하고 다듬는 프로토타입 단계**에 가깝습니다.

이미 들어가 있는 흐름:

- 책 등록
- 페이지 스캔
- OCR 텍스트 누적
- AI 요약 갱신
- 인물 정보 표시

아직 더 다듬어야 할 부분:

- 문서와 실제 코드 일치
- 일부 메타데이터 연결
- 삭제 로직 정리
- 관계도 일반화
- 테스트 보강


## 빠른 시작

실행과 환경설정은 아래 문서를 참고하면 됩니다.

- [SETUP.md](C:\WithAgent\Readassi\SETUP.md)


## 참고

- 앱 구조와 흐름 설명: [PROJECT_STRUCTURE.md](C:\WithAgent\Readassi\PROJECT_STRUCTURE.md)
- 저작권 및 출처: [ATTRIBUTIONS.md](C:\WithAgent\Readassi\ATTRIBUTIONS.md)
