import 'package:flutter/material.dart';

import '../state/app_tab.dart';
import '../state/connect_progress.dart';
import '../state/ssh_tab.dart';
import 'app_style.dart';
import 'widgets/common.dart';

/// 连接进度弹窗：左侧步骤，右侧实时日志，失败时标出出错的步骤。
///
/// [autoClose] 为 true 时连接成功后自动关闭并返回 true；用户取消或关闭返回 false。
/// 等待用户确认主机指纹 / 输入验证码时弹窗暂时隐藏，避免挡住对话框。
Future<bool> showConnectProgressDialog(
  BuildContext context,
  SshTab tab, {
  bool autoClose = true,
}) async {
  final r = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, _, _) => _ConnectDialog(tab: tab, autoClose: autoClose),
    transitionBuilder: (ctx, a, _, child) =>
        FadeTransition(opacity: a, child: child),
  );
  return r ?? false;
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.tab, required this.autoClose});
  final SshTab tab;
  final bool autoClose;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  bool _popped = false;

  /// 出现过一次后保持显示，重新连接时不闪烁。
  bool _shown = false;

  SshTab get tab => widget.tab;

  @override
  void initState() {
    super.initState();
    tab.progressViewer = true;
    tab.addListener(_onTab);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTab());
  }

  @override
  void dispose() {
    tab.removeListener(_onTab);
    tab.progressViewer = false;
    tab.progress?.answerHostKey(false);
    super.dispose();
  }

  void _onTab() {
    if (!mounted) return;
    if (widget.autoClose && tab.status == TabStatus.connected) {
      _pop(true);
    } else {
      setState(() {});
    }
  }

  void _pop(bool v) {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = tab.progress;
    if (p == null) return const SizedBox.expand();
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        if (!widget.autoClose ||
            tab.showProgress ||
            p.error != null ||
            p.hostKeyRequest != null) {
          _shown = true;
        }
        if (p.waitingUser || !_shown) return const SizedBox.expand();
        return ColoredBox(
          color: Colors.black.withValues(alpha: 0.45),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 780,
                  maxHeight: 520,
                ),
                child: _Panel(
                  tab: tab,
                  progress: p,
                  onClose: () {
                    p.answerHostKey(false);
                    _pop(false);
                  },
                  onRetry: tab.connect,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.tab,
    required this.progress,
    required this.onClose,
    required this.onRetry,
  });
  final SshTab tab;
  final ConnectProgress progress;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final p = progress;
    final failed = p.error != null;
    final done = p.finished && !failed;
    final req = p.hostKeyRequest;
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final (IconData icon, Color color, String title) = req != null
        ? req.changed
              ? (Icons.gpp_maybe_outlined, cs.error, '主机指纹已变化')
              : (Icons.vpn_key_outlined, cs.primary, '首次连接该主机')
        : failed
        ? (Icons.error_outline_rounded, cs.error, '连接失败')
        : done
        ? (Icons.check_circle_outline_rounded, const Color(0xFF22A06B), '连接日志')
        : (Icons.lan_outlined, cs.primary, '正在连接');
    return Material(
      color: st.dialogColor,
      elevation: 12,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(st.dialogRadius),
        side: BorderSide(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$title：${tab.config.displayName}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: narrow
                  ? Column(
                      children: [
                        SizedBox(height: 150, child: _Steps(progress: p)),
                        const SizedBox(height: 10),
                        Expanded(child: _Logs(progress: p)),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 210, child: _Steps(progress: p)),
                        const SizedBox(width: 12),
                        Expanded(child: _Logs(progress: p)),
                      ],
                    ),
            ),
          ),
          if (req != null) _HostKeyCard(request: req),
          if (failed && req == null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(st.controlRadius),
                border: Border.all(color: cs.error.withValues(alpha: 0.4)),
              ),
              child: SelectableText(
                p.error!,
                style: TextStyle(fontSize: 13, color: cs.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: Row(
              children: [
                AppButton(
                  label: '复制日志',
                  icon: Icons.copy_rounded,
                  onPressed: () =>
                      copyText(context, p.toText(), tip: '已复制连接日志'),
                ),
                const Spacer(),
                if (req != null) ...[
                  AppButton(label: '取消', onPressed: () => p.answerHostKey(false)),
                  const SizedBox(width: 8),
                  AppButton(
                    label: req.changed ? '仍然连接' : '信任并连接',
                    icon: req.changed ? null : Icons.verified_user_outlined,
                    primary: !req.changed,
                    danger: req.changed,
                    onPressed: () => p.answerHostKey(true),
                  ),
                ] else if (failed) ...[
                  AppButton(label: '关闭', onPressed: onClose),
                  const SizedBox(width: 8),
                  AppButton(
                    label: '重新连接',
                    icon: Icons.refresh_rounded,
                    primary: true,
                    onPressed: onRetry,
                  ),
                ] else
                  AppButton(label: done ? '关闭' : '取消', onPressed: onClose),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 嵌在进度弹窗里的主机指纹确认卡片。
class _HostKeyCard extends StatelessWidget {
  const _HostKeyCard({required this.request});
  final HostKeyRequest request;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final r = request;
    final accent = r.changed ? cs.error : cs.primary;
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['Consolas', 'Menlo', 'Cascadia Mono'],
      fontSize: 12.5,
    );
    Widget row(String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono.copyWith(color: color ?? cs.onSurface),
            ),
          ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(st.controlRadius),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.changed
                ? '主机指纹与之前记录的不一致，可能存在中间人攻击，也可能是服务器重装过系统。确认无误后再继续。'
                : '首次连接该主机，请核对指纹后确认是否信任。信任后会记住该指纹，下次不再询问。',
            style: TextStyle(
              fontSize: 12.5,
              color: r.changed ? cs.error : cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          row('主机', r.host),
          row('类型', r.type),
          if (r.changed) row('之前记录', r.known!),
          row(r.changed ? '当前指纹' : '指纹', r.fingerprint, color: accent),
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.progress});
  final ConnectProgress progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final steps = progress.steps;
    return ListView.builder(
      itemCount: steps.length,
      itemBuilder: (context, i) {
        final s = steps[i];
        final last = i == steps.length - 1;
        final color = switch (s.state) {
          ConnectStepState.done => const Color(0xFF22A06B),
          ConnectStepState.failed => cs.error,
          ConnectStepState.running => cs.primary,
        };
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 22,
                child: Column(
                  children: [
                    const SizedBox(height: 9),
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: switch (s.state) {
                        ConnectStepState.running => CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                        ConnectStepState.done => Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: color,
                        ),
                        ConnectStepState.failed => Icon(
                          Icons.cancel_rounded,
                          size: 16,
                          color: color,
                        ),
                      },
                    ),
                    if (!last)
                      Expanded(
                        child: Container(
                          width: 1.5,
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          color: cs.outlineVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    s.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: s.state == ConnectStepState.done
                          ? FontWeight.normal
                          : FontWeight.w600,
                      color: s.state == ConnectStepState.failed
                          ? cs.error
                          : s.state == ConnectStepState.running
                          ? cs.onSurface
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Logs extends StatelessWidget {
  const _Logs({required this.progress});
  final ConnectProgress progress;

  @override
  Widget build(BuildContext context) {
    final logs = progress.logs;
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0F12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: SelectionArea(
        child: ListView.builder(
          reverse: true,
          padding: const EdgeInsets.all(10),
          itemCount: logs.length,
          itemBuilder: (context, i) {
            final l = logs[logs.length - 1 - i];
            final t = l.time;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text:
                          '${two(t.hour)}:${two(t.minute)}:${two(t.second)}  ',
                      style: const TextStyle(color: Colors.white38),
                    ),
                    TextSpan(
                      text: l.text,
                      style: TextStyle(
                        color: l.error
                            ? const Color(0xFFFF6B6B)
                            : const Color(0xFFD7DAE0),
                      ),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas', 'Menlo', 'Cascadia Mono'],
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
