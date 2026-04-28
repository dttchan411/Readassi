# Readassi 실행 및 환경설정

## 1. 개요

이 문서는 현재 저장소 기준으로 Readassi Flutter 앱을 실행하기 위한 최소 설정을 정리한 문서입니다.

대상 프로젝트:

- [readassi_flutter](C:\WithAgent\Readassi\readassi_flutter)


## 2. 필요 도구

아래 항목이 준비되어 있어야 합니다.

- Flutter SDK
- Dart SDK
- Android Studio 또는 Xcode 중 개발 대상에 맞는 도구
- 실제 모바일 기기 또는 에뮬레이터

선택 사항:

- VS Code 또는 Android Studio


## 3. 현재 사용 중인 주요 패키지

`readassi_flutter/pubspec.yaml` 기준으로 아래 패키지를 사용합니다.

- `camera`
- `mobile_scanner`
- `http`
- `shared_preferences`
- `google_mlkit_document_scanner`
- `google_mlkit_object_detection`
- `path_provider`
- `path`
- `flutter_dotenv`


## 4. 환경 변수

앱은 `.env` 파일을 로드하도록 되어 있습니다.

위치:

- `readassi_flutter/.env`

현재 코드 기준으로 필요한 키:

- `_kakaoApiKey`
- `_googleBooksApiKey`
- `_googleVisionApiKey`
- `_geminiApiKey`

추가로 확인할 점:

- Claude 서비스는 `String.fromEnvironment`를 사용하고 있어 `.env` 방식이 아니라 **빌드 시 define 값**으로 주입되도록 작성되어 있습니다.
- 즉, Claude까지 실제로 연결하려면 현재 구현을 기준으로 `.env`만으로는 충분하지 않을 수 있습니다.


## 5. 예시 `.env`

아래는 형식 예시입니다.

```env
_kakaoApiKey=YOUR_KAKAO_API_KEY
_googleBooksApiKey=YOUR_GOOGLE_BOOKS_API_KEY
_googleVisionApiKey=YOUR_GOOGLE_VISION_API_KEY
_geminiApiKey=YOUR_GEMINI_API_KEY
```

주의:

- 실제 비밀키는 저장소에 커밋하지 않는 편이 좋습니다.


## 6. 설치

프로젝트 루트가 아니라 Flutter 폴더에서 작업합니다.

```powershell
cd C:\WithAgent\Readassi\readassi_flutter
flutter pub get
```


## 7. 실행

### 기본 실행

```powershell
cd C:\WithAgent\Readassi\readassi_flutter
flutter run
```

### 특정 define 값과 함께 실행하는 예시

Claude API를 현재 구현 그대로 쓰려면 `--dart-define` 방식이 필요할 수 있습니다.

```powershell
flutter run ^
  --dart-define=ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY ^
  --dart-define=ANTHROPIC_MODEL=claude-sonnet-4-20250514
```

Windows PowerShell에서는 한 줄로 실행해도 됩니다.

```powershell
flutter run --dart-define=ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY --dart-define=ANTHROPIC_MODEL=claude-sonnet-4-20250514
```


## 8. Android/iOS 권한 주의

이 앱은 아래 기능을 사용하므로 플랫폼별 권한 설정이 중요합니다.

- 카메라
- 네트워크
- 로컬 저장

특히 확인할 항목:

- Android 카메라 권한
- iOS 카메라 권한 설명 문구

현재 네이티브 설정 파일까지 세부 검증한 문서는 아니므로, 실제 실행 중 권한 오류가 나면 각 플랫폼 설정을 추가 점검해야 합니다.


## 9. 기능별 외부 연동 정리

### 책 등록

- Kakao Books API
- Google Books API

### OCR

- Google Vision API

### 독서 내용 통합 분석

- Gemini API

### 책 질문 답변

- Claude API


## 10. 현재 실행 전 체크리스트

실행 전에 아래를 확인하면 좋습니다.

- Flutter SDK 설치 완료
- `flutter doctor` 기본 통과
- `readassi_flutter/.env` 생성
- 필요한 API 키 입력
- 실제 기기 또는 에뮬레이터 준비


## 11. 알려진 주의사항

### 1. 루트 README와 실제 구현 차이

- 현재 저장소는 Flutter 구현이 중심입니다.

### 2. Claude 설정 방식이 다름

- 다른 키들은 `.env`에서 읽지만, Claude는 `String.fromEnvironment`를 사용합니다.
- 이 부분은 나중에 하나의 방식으로 통일하는 것이 좋습니다.

### 3. 외부 API 미설정 시 핵심 기능 제한

- `.env`가 없거나 키가 비어 있으면 책 등록, OCR, AI 분석이 제대로 동작하지 않습니다.


## 12. 권장 다음 작업

실행 환경을 안정적으로 만들려면 다음 작업이 도움이 됩니다.

1. `.env.example` 추가
2. Claude 설정 방식 통일
3. 플랫폼 권한 체크 문서화
4. 실제 실행 검증 절차 정리
