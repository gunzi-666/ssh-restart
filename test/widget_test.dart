import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/app_settings.dart';

void main() {
  test('AppSettings 默认值可正常序列化与反序列化', () {
    final s = AppSettings();
    final restored = AppSettings.fromJson(s.toJson());
    expect(restored.accentColor, s.accentColor);
    expect(restored.terminalTheme, s.terminalTheme);
  });

  testWidgets('空容器可正常渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(find.byType(SizedBox), findsOneWidget);
  });
}
