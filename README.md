# Readassi

`Readassi`는 책을 읽을 때 내용을 더 쉽게 따라가도록 도와주는 앱 프로토타입입니다.

현재 저장소에는 두 가지가 함께 들어 있습니다.

- 웹 앱: `React + Vite`로 만든 화면 시안
- 모바일 앱: `Flutter`로 만든 앱 프로젝트

## 이 프로젝트가 하는 일

웹 앱 기준으로 보면, 이런 화면들이 있습니다.

- 홈 화면: 읽고 있는 책 목록 보기
- 스캔 화면: 책 내용을 읽어들이는 흐름 표현
- 책 상세 화면: 등장인물, 관계, 진행률 같은 정보 보기
- 책 선택 화면: 새 책 고르기

아직은 서버에 연결된 완성 앱이라기보다, 아이디어를 보여주는 데모에 가깝습니다.
실제 데이터베이스 대신 코드 안에 들어 있는 예시 데이터(mock data)를 사용합니다.

## 폴더 구조

중요한 폴더만 쉽게 보면 아래와 같습니다.

```text
Readassi/
  src/                   웹 앱 소스코드
    app/
      components/        공통 UI 부품
      pages/             실제 화면들
      routes.tsx         페이지 주소 연결
      data.tsx           예시 책 데이터와 상태 관리
  readassi_flutter/      Flutter 앱 프로젝트
  dist/                  웹 앱 빌드 결과물
```

## 웹 앱 실행 방법

### 1. 준비물

아래 프로그램이 설치되어 있어야 합니다.

- Node.js
- npm

설치 확인은 터미널에서 아래 명령어로 할 수 있습니다.

```powershell
node -v
npm -v
```

### 2. 실행

프로젝트 폴더로 이동한 뒤 아래 순서대로 실행합니다.

```powershell
cd C:\WithAgent\Readassi
npm install
npm run dev
```

정상 실행되면 브라우저에서 개발 서버 주소가 나옵니다.
보통은 `http://localhost:5173` 입니다.

### 3. 배포용 빌드

```powershell
npm run build
```

빌드가 성공하면 결과물이 `dist/` 폴더에 만들어집니다.

## Flutter 앱 실행 방법

Flutter 프로젝트는 `readassi_flutter/` 폴더 안에 있습니다.

```powershell
cd C:\WithAgent\Readassi\readassi_flutter
flutter pub get
flutter run
```

Flutter SDK가 미리 설치되어 있어야 합니다.

## 초보자용 파일 설명

코드를 어디부터 봐야 할지 모르겠다면 이 순서로 보면 이해가 쉽습니다.

1. `src/main.tsx`
   웹 앱이 시작되는 가장 첫 파일입니다.
2. `src/app/App.tsx`
   전체 앱에 라우터를 연결합니다.
3. `src/app/routes.tsx`
   어떤 주소가 어떤 화면으로 가는지 정합니다.
4. `src/app/pages/Home.tsx`
   메인 화면입니다.
5. `src/app/data.tsx`
   책 데이터가 어디서 오는지 보여줍니다.

## 현재 확인한 상태

- 저장소 클론 완료
- 웹 앱 의존성 설치 완료
- `npm run build` 성공 확인

## 다음에 해보면 좋은 작업

- 깨진 한글 텍스트 정리
- 예시 데이터(mock data)를 실제 API 데이터로 교체
- 스캔 기능을 진짜 OCR 기능과 연결
- Flutter 앱과 웹 앱 역할 분리 정리

## 한 줄 요약

이 저장소는 "독서를 도와주는 앱"의 초기 데모 프로젝트이고, 지금은 웹 시안과 Flutter 앱 뼈대가 함께 들어 있는 상태입니다.
