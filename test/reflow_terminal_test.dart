import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/state/reflow_terminal.dart';
import 'package:xterm/xterm.dart';

String cursorLine(Terminal t) {
  final buf = t.buffer;
  return buf.lines[buf.absoluteCursorY].getText().trimRight();
}

void main() {
  for (final rows in [5, 10]) {
    test('重排后光标仍在提示符所在行（$rows 行）', () {
      final t = ReflowTerminal(maxLines: 1000)..resize(20, rows);
      for (var i = 0; i < 3; i++) {
        t.write('${'$i' * 50}\r\n');
      }
      t.write(r'$ ');

      t.resize(60, rows);
      t.write('ls');
      expect(cursorLine(t), r'$ ls');
      expect(t.buffer.lines[t.buffer.absoluteCursorY - 1].getText().trimRight(),
          '2' * 50);

      t.resize(20, rows);
      t.write('X');
      expect(cursorLine(t), r'$ lsX');
    });
  }

  test('宽度不变时不影响光标', () {
    final t = ReflowTerminal()..resize(20, 5);
    t.write('abc\r\n\$ ');
    t.resize(20, 8);
    t.write('x');
    expect(cursorLine(t), r'$ x');
  });
}
