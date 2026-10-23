import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../services/updater.dart';
import 'app_style.dart';
import 'widgets/shad.dart';

enum _Stage { checking, latest, available, downloading, installing, failed }

Future<void> showUpdateDialog(BuildContext context) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => const _UpdateDialog(),
);

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Stage _stage = _Stage.checking;
  String _current = '';
  ReleaseInfo? _release;
  String? _error;
  int _received = 0;
  int _total = 0;
  Completer<void>? _cancel;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _cancel?.complete();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _stage = _Stage.checking;
      _error = null;
    });
    try {
      _current = await Updater.currentVersion();
      final r = await Updater.fetchLatest();
      if (!mounted) return;
      setState(() {
        _release = r;
        _stage = Updater.compareVersions(r.version, _current) > 0
            ? _Stage.available
            : _Stage.latest;
      });
    } catch (e) {
      if (mounted) _fail('$e');
    }
  }

  void _fail(String msg) => setState(() {
    _stage = _Stage.failed;
    _error = msg;
  });

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  Future<void> _update() async {
    final r = _release!;
    final asset = Updater.assetFor(r);
    if (asset == null || !Updater.canSelfInstall) {
      await _open(asset?.url ?? r.pageUrl);
      return;
    }
    final cancel = _cancel = Completer<void>();
    setState(() {
      _stage = _Stage.downloading;
      _received = 0;
      _total = asset.size;
    });
    try {
      final file = await Updater.download(
        asset,
        cancel: cancel.future,
        onProgress: (got, total) {
          if (mounted) {
            setState(() {
              _received = got;
              _total = total;
            });
          }
        },
      );
      _cancel = null;
      if (!mounted) return;
      setState(() => _stage = _Stage.installing);
      await Updater.prepareInstall(file);
      await windowManager.close();
    } on UpdateCancelled {
      if (mounted) setState(() => _stage = _Stage.available);
    } catch (e) {
      _cancel = null;
      if (mounted) _fail('$e');
    }
  }

  void _cancelDownload() {
    _cancel?.complete();
    _cancel = null;
  }

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final r = _release;
    final close = AppButton(label: '关闭', onPressed: () => Navigator.pop(context));
    switch (_stage) {
      case _Stage.checking:
        return AppDialog(
          title: '检查更新',
          actions: [close],
          child: const Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('正在从 GitHub 获取最新版本…'),
            ],
          ),
        );
      case _Stage.latest:
        return AppDialog(
          title: '已是最新版本',
          description: '当前版本 $_current，GitHub 上最新发布的是 ${r!.tag}。',
          actions: [
            AppButton(label: '查看发布页', onPressed: () => _open(r.pageUrl)),
            AppButton(
              label: '好的',
              primary: true,
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      case _Stage.failed:
        return AppDialog(
          title: '更新失败',
          actions: [
            AppButton(
              label: '前往发布页',
              onPressed: () => _open(r?.pageUrl ?? Updater.releasesUrl),
            ),
            close,
            AppButton(
              label: '重试',
              icon: Icons.refresh_rounded,
              primary: true,
              onPressed: r == null ? _check : _update,
            ),
          ],
          child: SelectableText(
            _error ?? '',
            style: TextStyle(fontSize: 13, color: cs.error),
          ),
        );
      case _Stage.available:
      case _Stage.downloading:
      case _Stage.installing:
        final asset = Updater.assetFor(r!);
        final busy = _stage != _Stage.available;
        final selfInstall = asset != null && Updater.canSelfInstall;
        return AppDialog(
          title: '发现新版本 ${r.tag}',
          description:
              '当前版本 $_current'
              '${asset != null && asset.size > 0 ? '，安装包 ${_mb(asset.size)}' : ''}'
              '${selfInstall ? '。更新时会自动退出并在替换完成后重新打开。' : '。'}',
          width: 560,
          actions: [
            if (_stage == _Stage.downloading)
              AppButton(label: '取消下载', onPressed: _cancelDownload)
            else if (!busy) ...[
              AppButton(label: '查看发布页', onPressed: () => _open(r.pageUrl)),
              AppButton(label: '以后再说', onPressed: () => Navigator.pop(context)),
            ],
            AppButton(
              label: switch (_stage) {
                _Stage.downloading => '正在下载…',
                _Stage.installing => '正在安装…',
                _ => selfInstall ? '立即更新' : '前往下载',
              },
              icon: busy ? null : Icons.download_rounded,
              primary: true,
              onPressed: busy ? null : _update,
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(st.controlRadius),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      r.notes.isEmpty ? '（本次发布没有更新说明）' : r.notes,
                      style: const TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                  ),
                ),
              ),
              if (busy) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: _stage == _Stage.downloading && _total > 0
                      ? _received / _total
                      : null,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 6),
                Text(
                  _stage == _Stage.downloading
                      ? _total > 0
                            ? '${_mb(_received)} / ${_mb(_total)}'
                            : _mb(_received)
                      : Platform.isWindows
                      ? '正在解压并准备替换，程序即将退出…'
                      : '正在准备安装，程序即将退出…',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        );
    }
  }
}
