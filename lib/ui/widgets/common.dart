import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

void showToast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 3),
  ));
}

Future<void> copyText(BuildContext context, String text, {String? tip}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, tip ?? '已复制到剪贴板');
}

/// 统一的圆角标题样式：使用系统字体，保证中文标题完整显示、不被裁剪。
Widget _dialogTitle(BuildContext context, String title) => Text(
      title,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String? hint,
  bool obscure = false,
  int maxLines = 1,
  String okText = '确定',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogTitle(ctx, title),
              const SizedBox(height: 18),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: obscure,
                maxLines: obscure ? 1 : maxLines,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  isDense: true,
                ),
                onSubmitted:
                    maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, ctrl.text),
                        child: Text(okText)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
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
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dialogTitle(ctx, title),
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: cs.onSurfaceVariant)),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: danger
                            ? FilledButton.styleFrom(
                                backgroundColor: cs.error,
                                foregroundColor: cs.onError)
                            : null,
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(okText),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return r ?? false;
}

/// 统一风格的下拉选择框：普通下拉行为，圆角菜单、配色跟随主题。
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
    final cs = Theme.of(context).colorScheme;
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      borderRadius: BorderRadius.circular(12),
      dropdownColor: cs.surfaceContainerHigh,
      icon: Icon(CupertinoIcons.chevron_down,
          size: 15, color: cs.onSurfaceVariant),
      items: [
        for (final o in options)
          DropdownMenuItem(
              value: o.value,
              child: Text(o.label, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => onChanged(v as T),
    );
  }
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
            child: Text(text,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 可拖动的分隔条，用于调整面板尺寸。
class DragDivider extends StatelessWidget {
  const DragDivider({super.key, required this.onDrag, this.vertical = true});
  final void Function(double delta) onDrag;
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
              child: Text(label, style: const TextStyle(fontSize: 12))),
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
                Text(text,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
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
