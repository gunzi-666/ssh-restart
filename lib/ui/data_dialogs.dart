import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_store.dart';
import '../state/tabs_controller.dart';
import 'widgets/common.dart';

const clearAllConfirmPhrase = '我确认彻底删除所有本机数据';

/// 清除所有本机数据：必须输入确认文字才能执行。返回是否已清除。
Future<bool> showClearAllDataDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final cs = Theme.of(ctx).colorScheme;
        final match = ctrl.text.trim() == clearAllConfirmPhrase;
        return AppDialog(
          title: '清除所有数据',
          description:
              '将删除本机保存的全部服务器、分组、快捷命令、历史命令、主机指纹、设置和启动密码，'
              '数据目录中的数据库文件也会被删除。此操作无法撤销，建议先导出加密备份。',
          width: 460,
          actions: [
            AppButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            AppButton(
              label: '彻底删除',
              danger: true,
              onPressed: match ? () => Navigator.pop(ctx, true) : null,
            ),
          ],
          child: LabeledField(
            label: '请输入「$clearAllConfirmPhrase」以确认',
            child: TextField(
              controller: ctrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: clearAllConfirmPhrase,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: match ? cs.error : cs.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return false;
  final tabs = context.read<TabsController>();
  final store = context.read<AppStore>();
  await tabs.closeAll();
  await store.clearAllData();
  if (context.mounted) showToast(context, '已清除所有本机数据');
  return true;
}

/// 设置或修改启动密码。返回是否已设置。
Future<bool> showSetStartupPasswordDialog(
  BuildContext context, {
  bool change = false,
}) async {
  final store = context.read<AppStore>();
  final oldPw = TextEditingController();
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> submit() async {
          if (change && !await store.verifyStartupPassword(oldPw.text)) {
            setState(() => error = '当前密码不正确');
            return;
          }
          if (pw.text.length < 4) {
            setState(() => error = '密码至少 4 位');
            return;
          }
          if (pw.text != pw2.text) {
            setState(() => error = '两次输入的密码不一致');
            return;
          }
          await store.setStartupPassword(pw.text);
          if (ctx.mounted) Navigator.pop(ctx, true);
        }

        Widget field(
          String label,
          TextEditingController c, {
          bool autofocus = false,
        }) => LabeledField(
          label: label,
          child: TextField(
            controller: c,
            obscureText: true,
            autofocus: autofocus,
            style: const TextStyle(fontSize: 14),
            onSubmitted: (_) => submit(),
          ),
        );

        return AppDialog(
          title: change ? '修改启动密码' : '设置启动密码',
          description:
              '每次打开软件时需要输入此密码。启动密码只用于验证身份，'
              '本机数据不会因此加密；忘记密码只能清除所有本机数据后从备份恢复。',
          width: 440,
          actions: [
            AppButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            AppButton(label: '保存', primary: true, onPressed: submit),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (change) ...[
                field('当前密码', oldPw, autofocus: true),
                const SizedBox(height: 14),
              ],
              field('新密码', pw, autofocus: !change),
              const SizedBox(height: 14),
              field('确认新密码', pw2),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
  return ok == true;
}

/// 关闭启动密码前验证当前密码。
Future<bool> showDisableStartupPasswordDialog(BuildContext context) async {
  final store = context.read<AppStore>();
  final ctrl = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> submit() async {
          if (!await store.verifyStartupPassword(ctrl.text)) {
            setState(() => error = '密码不正确');
            return;
          }
          store.clearStartupPassword();
          if (ctx.mounted) Navigator.pop(ctx, true);
        }

        return AppDialog(
          title: '关闭启动密码',
          description: '请输入当前启动密码以确认关闭。',
          width: 420,
          actions: [
            AppButton(label: '取消', onPressed: () => Navigator.pop(ctx, false)),
            AppButton(label: '关闭密码', primary: true, onPressed: submit),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                onSubmitted: (_) => submit(),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
  return ok == true;
}
