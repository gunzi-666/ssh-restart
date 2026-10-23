import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_store.dart';
import 'app_style.dart';
import 'data_dialogs.dart';
import 'home_page.dart' show WindowButtons;
import 'widgets/common.dart';

/// 启动密码解锁页。
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await context.read<AppStore>().unlock(_ctrl.text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = '密码不正确';
      });
      _ctrl.clear();
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final customTitleBar = Platform.isWindows || Platform.isLinux;
    return Scaffold(
      body: Column(
        children: [
          if (customTitleBar)
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  const Expanded(
                    child: DragToMoveArea(child: SizedBox.expand()),
                  ),
                  const WindowButtons(),
                ],
              ),
            ),
          Expanded(child: _body(cs, st)),
        ],
      ),
    );
  }

  Widget _body(ColorScheme cs, AppStyle st) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
          decoration: BoxDecoration(
            color: st.dialogColor,
            borderRadius: BorderRadius.circular(st.dialogRadius),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 26,
                    color: cs.primary,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'SSH Restart 已锁定',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '请输入启动密码',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: true,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '启动密码',
                  errorText: _error,
                  prefixIcon: const Icon(Icons.key_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 14),
              AppButton(
                label: _busy ? '验证中…' : '解锁',
                primary: true,
                onPressed: _busy ? null : _submit,
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => showClearAllDataDialog(context),
                child: Text(
                  '忘记密码？清除所有数据',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
