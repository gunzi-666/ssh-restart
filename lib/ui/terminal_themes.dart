import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

TerminalTheme _theme({
  required Color fg,
  required Color bg,
  required Color cursor,
  required List<Color> ansi,
}) =>
    TerminalTheme(
      cursor: cursor,
      selection: cursor.withValues(alpha: 0.35),
      foreground: fg,
      background: bg,
      black: ansi[0],
      red: ansi[1],
      green: ansi[2],
      yellow: ansi[3],
      blue: ansi[4],
      magenta: ansi[5],
      cyan: ansi[6],
      white: ansi[7],
      brightBlack: ansi[8],
      brightRed: ansi[9],
      brightGreen: ansi[10],
      brightYellow: ansi[11],
      brightBlue: ansi[12],
      brightMagenta: ansi[13],
      brightCyan: ansi[14],
      brightWhite: ansi[15],
      searchHitBackground: const Color(0xFFFFFF2B),
      searchHitBackgroundCurrent: const Color(0xFF31FF26),
      searchHitForeground: const Color(0xFF000000),
    );

const _xtermAnsi = [
  Color(0xFF000000), Color(0xFFCD3131), Color(0xFF0DBC79), Color(0xFFE5E510),
  Color(0xFF2472C8), Color(0xFFBC3FBC), Color(0xFF11A8CD), Color(0xFFE5E5E5),
  Color(0xFF666666), Color(0xFFF14C4C), Color(0xFF23D18B), Color(0xFFF5F543),
  Color(0xFF3B8EEA), Color(0xFFD670D6), Color(0xFF29B8DB), Color(0xFFFFFFFF),
];

final Map<String, TerminalTheme> terminalThemes = {
  'FinalShell 暗色': _theme(
    fg: const Color(0xFFDCDCDC),
    bg: const Color(0xFF1B1D23),
    cursor: const Color(0xFFE0E0E0),
    ansi: _xtermAnsi,
  ),
  '经典黑底白字': TerminalThemes.whiteOnBlack,
  'VS Code 暗色': TerminalThemes.defaultTheme,
  '亮色': _theme(
    fg: const Color(0xFF2B2B2B),
    bg: const Color(0xFFFAFAFA),
    cursor: const Color(0xFF333333),
    ansi: const [
      Color(0xFF000000), Color(0xFFC91B00), Color(0xFF00A600), Color(0xFFA68A00),
      Color(0xFF0451A5), Color(0xFFBC05BC), Color(0xFF0598BC), Color(0xFF555555),
      Color(0xFF686868), Color(0xFFE74C3C), Color(0xFF16A34A), Color(0xFFB58900),
      Color(0xFF2563EB), Color(0xFFC026D3), Color(0xFF0891B2), Color(0xFF222222),
    ],
  ),
  'Solarized 暗色': _theme(
    fg: const Color(0xFF839496),
    bg: const Color(0xFF002B36),
    cursor: const Color(0xFF93A1A1),
    ansi: const [
      Color(0xFF073642), Color(0xFFDC322F), Color(0xFF859900), Color(0xFFB58900),
      Color(0xFF268BD2), Color(0xFFD33682), Color(0xFF2AA198), Color(0xFFEEE8D5),
      Color(0xFF002B36), Color(0xFFCB4B16), Color(0xFF586E75), Color(0xFF657B83),
      Color(0xFF839496), Color(0xFF6C71C4), Color(0xFF93A1A1), Color(0xFFFDF6E3),
    ],
  ),
  'Dracula': _theme(
    fg: const Color(0xFFF8F8F2),
    bg: const Color(0xFF282A36),
    cursor: const Color(0xFFF8F8F2),
    ansi: const [
      Color(0xFF21222C), Color(0xFFFF5555), Color(0xFF50FA7B), Color(0xFFF1FA8C),
      Color(0xFFBD93F9), Color(0xFFFF79C6), Color(0xFF8BE9FD), Color(0xFFF8F8F2),
      Color(0xFF6272A4), Color(0xFFFF6E6E), Color(0xFF69FF94), Color(0xFFFFFFA5),
      Color(0xFFD6ACFF), Color(0xFFFF92DF), Color(0xFFA4FFFF), Color(0xFFFFFFFF),
    ],
  ),
  'Monokai': _theme(
    fg: const Color(0xFFF8F8F2),
    bg: const Color(0xFF272822),
    cursor: const Color(0xFFF8F8F0),
    ansi: const [
      Color(0xFF272822), Color(0xFFF92672), Color(0xFFA6E22E), Color(0xFFF4BF75),
      Color(0xFF66D9EF), Color(0xFFAE81FF), Color(0xFFA1EFE4), Color(0xFFF8F8F2),
      Color(0xFF75715E), Color(0xFFF92672), Color(0xFFA6E22E), Color(0xFFF4BF75),
      Color(0xFF66D9EF), Color(0xFFAE81FF), Color(0xFFA1EFE4), Color(0xFFF9F8F5),
    ],
  ),
};

TerminalTheme terminalThemeByName(String name) =>
    terminalThemes[name] ?? terminalThemes.values.first;
