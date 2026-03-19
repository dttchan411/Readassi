import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:readassi_flutter/src/app.dart';

void main() {
  testWidgets('ReadAssi home renders', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ReadAssiApp());
    await tester.pumpAndSettle();

    expect(find.text('ReadAssi'), findsOneWidget);
    expect(find.text('AI 독서 보조 애플리케이션'), findsOneWidget);
  });
}
