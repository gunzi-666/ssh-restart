import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'shad.dart';

export 'shad.dart';

String formatBytes(num bytes, {int digits = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : digits)}${units[i]}';
}

String formatSpeed(num bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

String formatDuration(double seconds) {
  final s = seconds.floor();
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (d > 0) return '$d天 $h小时';
  if (h > 0) return '$h小时 $m分';
  return '$m分 ${s % 60}秒';
}

String formatDateTime(DateTime? t) {
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;

OverlayEntry? _toastEntry;

/// 顶部居中的轻提示：淡入并轻微下滑，自动消失；新提示会替换旧提示。
void showToast(BuildContext context, String msg) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _toastEntry?.remove();
  final error = RegExp('失败|错误|无法|不能|异常').hasMatch(msg);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: msg,
      error: error,
      onDone: () {
        if (_toastEntry == entry) {
          entry.remove();
          _toastEntry = null;
        }
      },
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.error,
    required this.onDone,
  });

  final String message;
  final bool error;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _c.forward();
    final ms = (1800 + widget.message.length * 40).clamp(1800, 4000);
    await Future<void>.delayed(Duration(milliseconds: ms));
    if (!mounted) return;
    await _c.reverse();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final curve = CurvedAnimation(
      parent: _c,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final accent = widget.error ? cs.error : const Color(0xFF22A06B);
    return Positioned(
      top: 52,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, -0.4),
                end: Offset.zero,
              ).animate(curve),
              child: ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.0).animate(curve),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Material(
                    color: dark ? const Color(0xFF26272B) : Colors.white,
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: cs.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.error
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_rounded,
                            size: 17,
                            color: accent,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              widget.message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> copyText(BuildContext context, String text, {String? tip}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, tip ?? '已复制到剪贴板');
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String? hint,
  String? description,
  bool obscure = false,
  int maxLines = 1,
  String okText = '确定',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final field = TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        minLines: 1,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
      );
      return AppDialog(
        title: title,
        description: description,
        width: 420,
        actions: [
          AppButton(label: '取消', onPressed: () => Navigator.pop(ctx)),
          AppButton(
            label: okText,
            primary: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text),
          ),
        ],
        child: label == null ? field : LabeledField(label: label, child: field),
      );
    },
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String okText = '确定',
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AppDialog(
      title: title,
      description: message,
      width: 420,
      actions: [
        AppButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
        AppButton(
          label: okText,
          primary: true,
          danger: danger,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return r ?? false;
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 可拖动的分隔条，用于调整面板尺寸。
class DragDivider extends StatelessWidget {
  const DragDivider({
    super.key,
    required this.onDrag,
    this.onStart,
    this.onEnd,
    this.vertical = true,
  });
  final void Function(double delta) onDrag;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).dividerColor;
    return MouseRegion(
      cursor: vertical
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: vertical ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: vertical ? null : (d) => onDrag(d.delta.dy),
        onHorizontalDragStart: vertical && onStart != null
            ? (_) => onStart!()
            : null,
        onVerticalDragStart: !vertical && onStart != null
            ? (_) => onStart!()
            : null,
        onHorizontalDragEnd: vertical && onEnd != null ? (_) => onEnd!() : null,
        onVerticalDragEnd: !vertical && onEnd != null ? (_) => onEnd!() : null,
        child: SizedBox(
          width: vertical ? 6 : double.infinity,
          height: vertical ? double.infinity : 6,
          child: Center(
            child: Container(
              width: vertical ? 1 : double.infinity,
              height: vertical ? double.infinity : 1,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class UsageBar extends StatelessWidget {
  const UsageBar({
    super.key,
    required this.label,
    required this.value,
    required this.text,
  });
  final String label;
  final double value;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = value > 0.9
        ? const Color(0xFFE5484D)
        : value > 0.7
        ? const Color(0xFFF5A524)
        : cs.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: value.clamp(0, 1),
                    minHeight: 18,
                    color: color,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一的圆角卡片容器：现代工具软件审美，适中圆角 + 1px 细边框分区。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.color,
    this.radius = 12,
    this.accent,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final double radius;

  /// 可选强调色：仅用于左侧一道细强调条，保持克制，不做彩色光晕。
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final br = BorderRadius.circular(radius);
    Widget content = Container(
      decoration: BoxDecoration(
        color: color ?? cs.surfaceContainer,
        borderRadius: br,
        border: Border(
          top: BorderSide(color: cs.outlineVariant),
          right: BorderSide(color: cs.outlineVariant),
          bottom: BorderSide(color: cs.outlineVariant),
          left: accent == null
              ? BorderSide(color: cs.outlineVariant)
              : BorderSide(color: accent!, width: 3),
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: br, onTap: onTap, child: content),
      );
    }
    return Padding(padding: margin ?? EdgeInsets.zero, child: content);
  }
}
