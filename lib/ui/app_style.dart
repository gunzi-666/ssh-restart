import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 内置界面风格。
enum UiStyle {
  standard('default', '默认', 'shadcn/ui 风格：中性灰、细边框、克制的圆角'),
  fluent('fluent', 'Fluent', '微软 Fluent 2 / Windows 11 风格：小圆角、云母底色、下划线标签'),
  antd('antd', 'Ant Design', '蚂蚁 Ant Design 5 风格：纯净深色、主色强调、选中项着色');

  const UiStyle(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static UiStyle parse(String id) =>
      values.firstWhere((e) => e.id == id, orElse: () => standard);
}

enum TabVariant { segmented, underline }

/// 各风格的设计参数，组件通过 [AppStyle.of] 读取。
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle({
    required this.style,
    required this.controlRadius,
    required this.itemRadius,
    required this.menuRadius,
    required this.dialogRadius,
    required this.cardRadius,
    required this.controlHeight,
    required this.popover,
    required this.dialogColor,
    required this.inputFill,
    required this.muted,
    required this.segmentActive,
    required this.hover,
    required this.secondaryFill,
    required this.focusColor,
    required this.tabVariant,
    required this.tintSelected,
  });

  final UiStyle style;
  final double controlRadius;
  final double itemRadius;
  final double menuRadius;
  final double dialogRadius;
  final double cardRadius;
  final double controlHeight;
  final Color popover;
  final Color dialogColor;
  final Color inputFill;
  final Color muted;
  final Color segmentActive;
  final Color hover;
  final Color secondaryFill;
  final Color focusColor;
  final TabVariant tabVariant;

  /// 菜单/下拉中的选中项是否以主色底色高亮（否则右侧打勾）。
  final bool tintSelected;

  static AppStyle of(BuildContext context) =>
      Theme.of(context).extension<AppStyle>()!;

  @override
  AppStyle copyWith() => this;

  @override
  AppStyle lerp(covariant AppStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

class _Palette {
  const _Palette({
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.highest,
    required this.border,
    this.onSurface,
    this.onSurfaceVariant,
  });

  final Color surface;
  final Color lowest;
  final Color low;
  final Color container;
  final Color high;
  final Color highest;
  final Color border;
  final Color? onSurface;
  final Color? onSurfaceVariant;
}

_Palette _palette(UiStyle style, bool dark) => switch ((style, dark)) {
      (UiStyle.standard, true) => const _Palette(
          surface: Color(0xFF1E1E22),
          lowest: Color(0xFF191A1D),
          low: Color(0xFF242428),
          container: Color(0xFF2A2A2F),
          high: Color(0xFF313137),
          highest: Color(0xFF3A3A41),
          border: Color(0xFF3A3A41),
        ),
      (UiStyle.standard, false) => const _Palette(
          surface: Color(0xFFFFFFFF),
          lowest: Color(0xFFFFFFFF),
          low: Color(0xFFF2F3F5),
          container: Color(0xFFFFFFFF),
          high: Color(0xFFEDEEF1),
          highest: Color(0xFFE4E6EA),
          border: Color(0xFFD9DCE1),
        ),
      (UiStyle.fluent, true) => const _Palette(
          surface: Color(0xFF202020),
          lowest: Color(0xFF1C1C1C),
          low: Color(0xFF272727),
          container: Color(0xFF2B2B2B),
          high: Color(0xFF323232),
          highest: Color(0xFF3C3C3C),
          border: Color(0xFF383838),
          onSurface: Color(0xFFFFFFFF),
          onSurfaceVariant: Color(0xFFB4B4B4),
        ),
      (UiStyle.fluent, false) => const _Palette(
          surface: Color(0xFFF3F3F3),
          lowest: Color(0xFFFFFFFF),
          low: Color(0xFFEEEEEE),
          container: Color(0xFFFBFBFB),
          high: Color(0xFFEBEBEB),
          highest: Color(0xFFE0E0E0),
          border: Color(0xFFE0E0E0),
          onSurface: Color(0xFF1B1B1B),
          onSurfaceVariant: Color(0xFF5F5F5F),
        ),
      (UiStyle.antd, true) => const _Palette(
          surface: Color(0xFF141414),
          lowest: Color(0xFF0A0A0A),
          low: Color(0xFF1A1A1A),
          container: Color(0xFF1F1F1F),
          high: Color(0xFF262626),
          highest: Color(0xFF303030),
          border: Color(0xFF303030),
          onSurface: Color(0xFFE6E6E6),
          onSurfaceVariant: Color(0xFFA6A6A6),
        ),
      (UiStyle.antd, false) => const _Palette(
          surface: Color(0xFFF5F5F5),
          lowest: Color(0xFFFFFFFF),
          low: Color(0xFFFAFAFA),
          container: Color(0xFFFFFFFF),
          high: Color(0xFFF0F0F0),
          highest: Color(0xFFE8E8E8),
          border: Color(0xFFD9D9D9),
          onSurface: Color(0xFF262626),
          onSurfaceVariant: Color(0xFF595959),
        ),
    };

AppStyle _tokens(UiStyle style, bool dark, ColorScheme cs) {
  final hover = cs.onSurface.withValues(alpha: dark ? 0.08 : 0.05);
  switch (style) {
    case UiStyle.standard:
      return AppStyle(
        style: style,
        controlRadius: 8,
        itemRadius: 5,
        menuRadius: 8,
        dialogRadius: 12,
        cardRadius: 14,
        controlHeight: 40,
        popover: dark ? cs.surfaceContainerLow : cs.surface,
        dialogColor: cs.surface,
        inputFill: dark ? cs.surfaceContainerLow : Colors.white,
        muted: dark ? cs.surfaceContainer : cs.surfaceContainerLow,
        segmentActive: dark ? cs.surfaceContainerHighest : Colors.white,
        hover: hover,
        secondaryFill: Colors.transparent,
        focusColor: cs.onSurfaceVariant.withValues(alpha: 0.8),
        tabVariant: TabVariant.segmented,
        tintSelected: false,
      );
    case UiStyle.fluent:
      return AppStyle(
        style: style,
        controlRadius: 4,
        itemRadius: 4,
        menuRadius: 8,
        dialogRadius: 8,
        cardRadius: 8,
        controlHeight: 34,
        popover: dark ? const Color(0xFF2C2C2C) : const Color(0xFFF9F9F9),
        dialogColor: dark ? const Color(0xFF2B2B2B) : const Color(0xFFFBFBFB),
        inputFill: dark ? const Color(0xFF2D2D2D) : Colors.white,
        muted: dark ? const Color(0xFF1F1F1F) : const Color(0xFFEBEBEB),
        segmentActive: dark ? const Color(0xFF3C3C3C) : Colors.white,
        hover: hover,
        secondaryFill: dark ? const Color(0xFF353535) : Colors.white,
        focusColor: cs.primary,
        tabVariant: TabVariant.underline,
        tintSelected: false,
      );
    case UiStyle.antd:
      return AppStyle(
        style: style,
        controlRadius: 6,
        itemRadius: 4,
        menuRadius: 8,
        dialogRadius: 8,
        cardRadius: 8,
        controlHeight: 34,
        popover: dark ? const Color(0xFF1F1F1F) : Colors.white,
        dialogColor: dark ? const Color(0xFF1F1F1F) : Colors.white,
        inputFill: dark ? const Color(0xFF141414) : Colors.white,
        muted: dark ? const Color(0xFF0F0F0F) : const Color(0xFFF5F5F5),
        segmentActive: dark ? const Color(0xFF3A3A3A) : Colors.white,
        hover: hover,
        secondaryFill: Colors.transparent,
        focusColor: cs.primary,
        tabVariant: TabVariant.underline,
        tintSelected: true,
      );
  }
}

ThemeData buildAppTheme(Brightness b, Color accent, UiStyle style) {
  final dark = b == Brightness.dark;
  final p = _palette(style, dark);
  var scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
    surface: p.surface,
    surfaceContainerLowest: p.lowest,
    surfaceContainerLow: p.low,
    surfaceContainer: p.container,
    surfaceContainerHigh: p.high,
    surfaceContainerHighest: p.highest,
    outlineVariant: p.border,
  );
  if (p.onSurface != null) {
    scheme = scheme.copyWith(
      onSurface: p.onSurface,
      onSurfaceVariant: p.onSurfaceVariant,
      primary: accent,
      onPrimary: Colors.white,
    );
  }
  final t = _tokens(style, dark, scheme);
  final border = p.border;
  final ctrl = BorderRadius.circular(t.controlRadius);
  final inputV = (t.controlHeight - 20) / 2;
  final fluentFont =
      style == UiStyle.fluent && !kIsWeb && Platform.isWindows;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [t],
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    fontFamily: fluentFont ? 'Segoe UI Variable Text' : null,
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC'
    ],
    dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainer,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.cardRadius),
        side: BorderSide(color: border, width: 1),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: t.inputFill,
      hintStyle: TextStyle(
          fontSize: 14,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
      border: OutlineInputBorder(
          borderRadius: ctrl, borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: ctrl, borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
        borderRadius: ctrl,
        borderSide: BorderSide(color: t.focusColor, width: 1.4),
      ),
      contentPadding:
          EdgeInsets.symmetric(horizontal: 12, vertical: inputV),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: ctrl),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: ctrl),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        backgroundColor: t.secondaryFill,
        shape: RoundedRectangleBorder(borderRadius: ctrl),
        side: BorderSide(color: border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: ctrl),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.controlRadius),
        side: BorderSide(color: border),
      ),
      side: BorderSide(color: border),
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.primary,
      showCheckmark: false,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: ctrl)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.dialogColor,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.dialogRadius),
        side: BorderSide(color: border),
      ),
      titleTextStyle: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.popover,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      menuPadding: const EdgeInsets.all(4),
      textStyle: TextStyle(fontSize: 14, color: scheme.onSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.menuRadius),
        side: BorderSide(color: border),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.popover),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor:
            WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.35)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.menuRadius),
            side: BorderSide(color: border),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(180, 34)),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
        iconSize: const WidgetStatePropertyAll(16),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.itemRadius))),
        overlayColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
                ? t.hover
                : null),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: ctrl),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.itemRadius + 2)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      height: 64,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      useIndicator: true,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
              ? (style == UiStyle.standard
                  ? const Color(0xFF34C759)
                  : scheme.primary)
              : null),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(8),
      thumbColor: WidgetStatePropertyAll(
          scheme.onSurface.withValues(alpha: dark ? 0.22 : 0.26)),
    ),
    tooltipTheme:
        const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
  );
}
