import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';
import 'package:ssh_restart/ui/command_panels.dart';

void main() {
  testWidgets('旧版数据（无排序字段、多行、空名称）在弹窗中能正常渲染', (tester) async {
    final store = AppStore();
    final legacy = [
      for (var i = 0; i < 80; i++)
        QuickCommand.fromJson({
          'id': 'id$i',
          'group': ['运维', 'swap', '证书', '', '默认'][i % 5],
          'name': i % 7 == 0 ? '' : '命令$i',
          'command': i % 3 == 0 ? 'cd /tmp\nls -la\necho $i' : 'echo ${'x' * (i * 3)}',
          'appendEnter': i.isEven,
        }),
    ];
    store.mergeBackup(sessions: const [], groups: const [], quickCommands: legacy);

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog(
                  context: context,
                  builder: (ctx) => Dialog(
                    child: SizedBox(
                      width: 680,
                      height: 480,
                      child: QuickCommandPanel(onSend: (_) {}),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('运维'), findsOneWidget);
    expect(find.textContaining('命令1'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });
}
