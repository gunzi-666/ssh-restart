import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_style.dart';

/// 基础组件：弹窗、菜单、下拉选择、分段切换、带标签的表单项。
/// 圆角、配色、高度等均取自当前界面风格 [AppStyle]。

OutlinedBorder _popoverShape(BuildContext context) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppStyle.of(context).menuRadius),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    );

// ───────────────────────── 弹窗 ─────────────────────────

/// 弹窗外壳：细边框、无色调叠加。
class AppDialogShell extends StatelessWidget {
  const AppDialogShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    return Dialog(
      backgroundColor: st.dialogColor,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(st.dialogRadius),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: child,
    );
  }
}

/// 弹窗标题区：左对齐标题 + 说明文字，右上角关闭按钮。
class AppDialogHeader extends StatelessWidget {
  const AppDialogHeader({super.key, required this.title, this.description});
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: cs.onSurface)),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(description!,
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        _CloseButton(onTap: () => Navigator.maybePop(context)),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '关闭',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppStyle.of(context).itemRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.close_rounded, size: 18, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 标准弹窗：标题、说明、内容、右对齐的底部按钮。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.description,
    this.child,
    this.actions = const [],
    this.width = 440,
  });

  final String title;
  final String? description;
  final Widget? child;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    return AppDialogShell(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppDialogHeader(title: title, description: description),
              if (child != null) ...[
                const SizedBox(height: 20),
                Flexible(child: child!),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 按钮：次要按钮为描边样式，主要按钮为实心样式，危险操作为红色。
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    const pad = EdgeInsets.symmetric(horizontal: 16);
    final size = Size(72, st.controlHeight - 2);
    final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(st.controlRadius));
    const text = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    final content = icon == null
        ? Text(label)
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16),
            const SizedBox(width: 8),
            Text(label),
          ]);
    if (primary || danger) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: danger ? cs.error : null,
          foregroundColor: danger ? cs.onError : null,
          padding: pad,
          minimumSize: size,
          shape: shape,
          textStyle: text,
        ),
        child: content,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: cs.onSurface,
        backgroundColor: st.secondaryFill,
        side: BorderSide(color: cs.outlineVariant),
        padding: pad,
        minimumSize: size,
        shape: shape,
        textStyle: text,
      ),
      child: content,
    );
  }
}

// ───────────────────────── 表单 ─────────────────────────

/// 标签在上、控件在下的表单项。
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface)),
        const SizedBox(height: 7),
        child,
      ],
    );
  }
}

BoxDecoration _activeSegment(AppStyle st) => BoxDecoration(
      color: st.segmentActive,
      borderRadius: BorderRadius.circular(math.max(2, st.controlRadius - 2)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ],
    );

/// 分段切换。
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<({T value, String label, IconData? icon})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    return Container(
      height: st.controlHeight - 2,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: st.muted,
        borderRadius: BorderRadius.circular(st.controlRadius),
      ),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(o.value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    decoration: o.value == value
                        ? _activeSegment(st)
                        : const BoxDecoration(),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (o.icon != null) ...[
                          Icon(o.icon,
                              size: 15,
                              color: o.value == value
                                  ? cs.onSurface
                                  : cs.onSurfaceVariant),
                          const SizedBox(width: 6),
                        ],
                        Text(o.label,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: o.value == value
                                    ? cs.onSurface
                                    : cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 配合 DefaultTabController 使用的标签栏：分段样式或下划线样式（随风格）。
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.tabs, this.scrollable = false});
  final List<String> tabs;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    const style = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500);
    if (st.tabVariant == TabVariant.underline) {
      final antd = st.style == UiStyle.antd;
      return TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: cs.primary, width: antd ? 2 : 3),
          borderRadius: BorderRadius.circular(2),
          insets: EdgeInsets.symmetric(horizontal: antd ? 0 : 10),
        ),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: cs.outlineVariant,
        dividerHeight: 1,
        labelColor: antd ? cs.primary : cs.onSurface,
        unselectedLabelColor: cs.onSurfaceVariant,
        labelStyle: style.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: style,
        labelPadding: EdgeInsets.only(right: antd ? 28 : 8, left: antd ? 0 : 8),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        tabs: [for (final t in tabs) Tab(height: 38, text: t)],
      );
    }
    return Container(
      height: st.controlHeight - 2,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: st.muted,
        borderRadius: BorderRadius.circular(st.controlRadius),
      ),
      child: TabBar(
        isScrollable: scrollable,
        tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
        indicator: _activeSegment(st),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerHeight: 0,
        labelColor: cs.onSurface,
        unselectedLabelColor: cs.onSurfaceVariant,
        labelStyle: style,
        unselectedLabelStyle: style,
        labelPadding: const EdgeInsets.symmetric(horizontal: 14),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        tabs: [for (final t in tabs) Tab(height: 32, text: t)],
      ),
    );
  }
}

// ───────────────────────── 菜单 ─────────────────────────

/// 菜单项：悬停时显示内缩的圆角高亮。
class AppMenuItem extends StatefulWidget {
  const AppMenuItem({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.trailing,
    this.danger = false,
    this.enabled = true,
    this.selected = false,
    this.height = 34,
    this.reserveIconSpace = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool reserveIconSpace;
  final Widget? trailing;
  final bool danger;
  final bool enabled;
  final bool selected;
  final double height;

  @override
  State<AppMenuItem> createState() => _AppMenuItemState();
}

class _AppMenuItemState extends State<AppMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final tinted = st.tintSelected && widget.selected;
    final fg = !widget.enabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : widget.danger
            ? cs.error
            : tinted
                ? cs.primary
                : cs.onSurface;
    final hoverBg =
        widget.danger ? cs.error.withValues(alpha: 0.12) : st.hover;
    Color? bg;
    if (tinted) {
      bg = cs.primary.withValues(alpha: 0.16);
    } else if (_hover && widget.enabled) {
      bg = hoverBg;
    }
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(st.itemRadius),
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon,
                    size: 16,
                    color: widget.danger || !widget.enabled || tinted
                        ? fg
                        : cs.onSurfaceVariant),
                const SizedBox(width: 10),
              ] else if (widget.reserveIconSpace)
                const SizedBox(width: 26),
              Flexible(
                fit: FlexFit.tight,
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: fg,
                        fontWeight: widget.selected
                            ? (tinted ? FontWeight.w600 : FontWeight.w500)
                            : FontWeight.normal)),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 12),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AppMenuEntry<T> {
  const AppMenuEntry(
    T this.value,
    this.label, {
    this.icon,
    this.danger = false,
    this.enabled = true,
    this.shortcut,
  }) : divider = false;

  const AppMenuEntry.divider()
      : value = null,
        label = '',
        icon = null,
        danger = false,
        enabled = false,
        shortcut = null,
        divider = true;

  final T? value;
  final String label;
  final IconData? icon;
  final bool danger;
  final bool enabled;
  final String? shortcut;
  final bool divider;
}

class _MenuPosition extends SingleChildLayoutDelegate {
  _MenuPosition(this.pos);
  final Offset pos;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(c.biggest).deflate(const EdgeInsets.all(8));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = pos.dx;
    var y = pos.dy;
    if (x + child.width > size.width - 8) {
      x = math.max(8, x - child.width);
    }
    if (y + child.height > size.height - 8) {
      y = math.max(8, size.height - 8 - child.height);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPosition old) => old.pos != pos;
}

/// 在指定全局坐标弹出上下文菜单，返回所选项的 value。
Future<T?> showAppMenu<T>(
  BuildContext context,
  Offset position,
  List<AppMenuEntry<T>> entries, {
  double minWidth = 188,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (ctx, _, _) => CustomSingleChildLayout(
      delegate: _MenuPosition(position),
      child: _MenuPanel<T>(entries: entries, minWidth: minWidth),
    ),
    transitionBuilder: (ctx, a, _, child) =>
        FadeTransition(opacity: a, child: child),
  );
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({required this.entries, required this.minWidth});
  final List<AppMenuEntry<T>> entries;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final anyIcon = entries.any((e) => e.icon != null);
    return Material(
      color: AppStyle.of(context).popover,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      shape: _popoverShape(context),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth, maxWidth: 320),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in entries)
                  if (e.divider)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Divider(height: 1, color: cs.outlineVariant),
                    )
                  else
                    AppMenuItem(
                      label: e.label,
                      icon: e.icon,
                      reserveIconSpace: anyIcon,
                      danger: e.danger,
                      enabled: e.enabled,
                      trailing: e.shortcut == null
                          ? null
                          : Text(e.shortcut!,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant)),
                      onTap: () => Navigator.pop(context, e.value),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 下拉选择 ─────────────────────────

String _labelOf<T>(List<({T value, String label})> options, T value) {
  for (final o in options) {
    if (o.value == value) return o.label;
  }
  return '';
}

/// 下拉选择：触发控件 + 与之等宽的弹出列表。
class _SelectMenu<T> extends StatelessWidget {
  const _SelectMenu({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.builder,
    this.minMenuWidth = 140,
  });

  final T value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;
  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
      builder;
  final double minMenuWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    return LayoutBuilder(builder: (context, c) {
      final menuW = c.hasBoundedWidth
          ? math.max(c.maxWidth, minMenuWidth)
          : minMenuWidth;
      return MenuAnchor(
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(st.popover),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(12),
          shadowColor:
              WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.35)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          shape: WidgetStatePropertyAll(_popoverShape(context)),
          maximumSize: const WidgetStatePropertyAll(Size(520, 380)),
        ),
        menuChildren: [
          for (final o in options)
            SizedBox(
              width: menuW - 8,
              child: Builder(
                builder: (itemCtx) => AppMenuItem(
                  height: 36,
                  label: o.label,
                  selected: o.value == value,
                  trailing: st.tintSelected
                      ? null
                      : o.value == value
                          ? Icon(Icons.check_rounded,
                              size: 16, color: cs.onSurface)
                          : const SizedBox(width: 16),
                  onTap: () {
                    MenuController.maybeOf(itemCtx)?.close();
                    onChanged(o.value);
                  },
                ),
              ),
            ),
        ],
        builder: (context, controller, _) => builder(
          context,
          controller.isOpen,
          () => controller.isOpen ? controller.close() : controller.open(),
        ),
      );
    });
  }
}

class _SelectTrigger extends StatelessWidget {
  const _SelectTrigger({
    required this.text,
    required this.open,
    required this.onTap,
    required this.height,
    required this.fontSize,
  });

  final String text;
  final bool open;
  final VoidCallback onTap;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final radius = BorderRadius.circular(st.controlRadius);
    return Material(
      color: st.inputFill,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: open ? st.focusColor : cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        hoverColor: st.hover,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: fontSize, color: cs.onSurface)),
                ),
                const SizedBox(width: 6),
                Icon(
                    st.style == UiStyle.standard
                        ? Icons.unfold_more_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: fontSize + 4,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 下拉选择按钮，用于设置项右侧、面板标题栏等。
class AppSelect<T> extends StatelessWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 140,
    this.dense = false,
  });

  final T value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;
  final double width;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final st = AppStyle.of(context);
    return SizedBox(
      width: width,
      child: _SelectMenu<T>(
        value: value,
        options: options,
        onChanged: onChanged,
        builder: (context, open, toggle) => _SelectTrigger(
          text: _labelOf(options, value),
          open: open,
          onTap: toggle,
          height: dense ? 30 : st.controlHeight - 2,
          fontSize: dense ? 12.5 : 14,
        ),
      ),
    );
  }
}

/// 表单中的下拉选择：标签在上，触发器与输入框同高。
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: _SelectMenu<T>(
        value: value,
        options: options,
        onChanged: onChanged,
        builder: (context, open, toggle) => _SelectTrigger(
          text: _labelOf(options, value),
          open: open,
          onTap: toggle,
          height: AppStyle.of(context).controlHeight,
          fontSize: 14,
        ),
      ),
    );
  }
}
