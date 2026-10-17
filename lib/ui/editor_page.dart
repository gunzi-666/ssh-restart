import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ssh/sftp_service.dart';
import 'widgets/common.dart';

/// 内置文本编辑器：读取远程文件、编辑后保存回服务器，支持查找。
class RemoteEditorPage extends StatefulWidget {
  const RemoteEditorPage({super.key, required this.sftp, required this.path});
  final SftpService sftp;
  final String path;

  @override
  State<RemoteEditorPage> createState() => _RemoteEditorPageState();
}

class _RemoteEditorPageState extends State<RemoteEditorPage> {
  final _ctrl = TextEditingController();
  final _find = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String _original = '';
  bool _loading = true;
  bool _saving = false;
  bool _wrap = false;
  bool _showFind = false;
  String? _error;

  bool get _dirty => _ctrl.text != _original;

  @override
  void initState() {
    super.initState();
    _load();
    _ctrl.addListener(() => setState(() {}));
  }

  Future<void> _load() async {
    try {
      final text = await widget.sftp.readText(widget.path);
      _original = text;
      _ctrl.text = text;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.sftp.writeText(widget.path, _ctrl.text);
      _original = _ctrl.text;
      if (mounted) showToast(context, '已保存');
    } catch (e) {
      if (mounted) showToast(context, '保存失败：$e');
    }
    if (mounted) setState(() => _saving = false);
  }

  void _findNext() {
    final q = _find.text;
    if (q.isEmpty) return;
    final text = _ctrl.text;
    final start = _ctrl.selection.end < 0 ? 0 : _ctrl.selection.end;
    var idx = text.indexOf(q, start);
    if (idx < 0) idx = text.indexOf(q);
    if (idx < 0) {
      showToast(context, '未找到');
      return;
    }
    _ctrl.selection = TextSelection(baseOffset: idx, extentOffset: idx + q.length);
    _focus.requestFocus();
  }

  Future<bool> _onWillPop() async {
    if (!_dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文件已修改'),
        content: const Text('是否保存修改？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('不保存')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('保存')),
        ],
      ),
    );
    if (r == 'save') {
      await _save();
      return !_dirty;
    }
    return r == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final editor = TextField(
      controller: _ctrl,
      focusNode: _focus,
      scrollController: _scroll,
      maxLines: null,
      expands: true,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Consolas', 'Menlo'], fontSize: 13.5, height: 1.35),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(12),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _onWillPop()) nav.pop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              setState(() => _showFind = true),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text('${_dirty ? '● ' : ''}$name', overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: '查找 (Ctrl+F)',
                icon: const Icon(Icons.search),
                onPressed: () => setState(() => _showFind = !_showFind),
              ),
              IconButton(
                tooltip: _wrap ? '取消自动换行' : '自动换行',
                icon: Icon(_wrap ? Icons.wrap_text : Icons.notes),
                onPressed: () => setState(() => _wrap = !_wrap),
              ),
              IconButton(
                tooltip: '重新加载',
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _saving || !_dirty ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : Column(
                      children: [
                        if (_showFind)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _find,
                                    autofocus: true,
                                    decoration: const InputDecoration(hintText: '查找内容'),
                                    onSubmitted: (_) => _findNext(),
                                  ),
                                ),
                                IconButton(onPressed: _findNext, icon: const Icon(Icons.arrow_downward)),
                                IconButton(
                                    onPressed: () => setState(() => _showFind = false),
                                    icon: const Icon(Icons.close)),
                              ],
                            ),
                          ),
                        Expanded(
                          child: _wrap
                              ? editor
                              : LayoutBuilder(
                                  builder: (context, c) => SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                      width: c.maxWidth < 2400 ? 2400 : c.maxWidth,
                                      height: c.maxHeight,
                                      child: editor,
                                    ),
                                  ),
                                ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${widget.path}    ${_ctrl.text.split('\n').length} 行    UTF-8',
                            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
