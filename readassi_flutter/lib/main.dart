import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // 1. 패키지 임포트 추가
import 'src/app.dart';

Future<void> main() async {
  // 2. Flutter 바인딩 초기화 (비동기 작업을 main에서 할 때 필수)
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
    print("성공: .env 파일을 불러왔습니다.");
  } catch (e) {
    print("실패: .env 파일을 찾을 수 없습니다. 경로를 확인하세요: $e");
  }

  runApp(const ReadAssiApp());
}