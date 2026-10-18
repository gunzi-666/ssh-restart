import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/vs.dart';

import '../state/editor_file.dart';
import 'widgets/common.dart';

const double _kFontSize = 13.5;
const double _kFontHeight = 1.4;
const double _kLineHeight = _kFontSize * _kFontHeight;

/// 编辑副标签的内容视图：嵌在 SSH 会话内（副标签下方），
/// 提供行号 + 语法高亮 + 查找替换 + minimap + 行书签。
class EditorTabView extends StatefulWidget {
  const EditorTabView({super.key, required this.file});
  final EditorFile file;

  @override
  State<EditorTabView> createState() => _EditorTabViewState();
}

class _EditorTabViewState extends State<EditorTabView> {
  bool _showBookmarks = false;
  bool _showMinimap = true;

  EditorFile get file => widget.file;

  Future<void> _save() async {
    final err = await file.save();
    if (!mounted) return;
    showToast(context, err == null ? '已保存' : '保存失败：$err');
  }

  void _toggleBookmarkAtCursor() {
    file.toggleBookmark(file.controller.selection.baseIndex);
  }

  void _jumpToLine(int line) {
    file.controller.selection =
        CodeLineSelection.collapsed(index: line, offset: 0);
    final sc = file.scroll.verticalScroller;
    if (sc.hasClients) {
      final target =
          (line * _kLineHeight - 80).clamp(0.0, sc.position.maxScrollExtent);
      sc.animateTo(target,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: file,
      builder: (context, _) {
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _save,
            const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                _toggleBookmarkAtCursor,
          },
          child: Column(
            children: [
              _toolbar(),
              const Divider(height: 1),
              Expanded(
                child: file.loading
                    ? const Center(child: CircularProgressIndicator())
                    : file.error != null
                        ? Center(child: Text(file.error!))
                        : Row(
                            children: [
                              Expanded(child: _editor()),
                              if (_showMinimap)
                                _Minimap(
                                    key: ValueKey('mm-${file.path}'),
                                    file: file),
                              if (_showBookmarks)
                                _BookmarkPanel(
                                  file: file,
                                  onJump: _jumpToLine,
                                  onRemove: file.toggleBookmark,
                                ),
                            ],
                          ),
              ),
              _statusBar(),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Icon(Icons.description_outlined,
              size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(file.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          const Spacer(),
          IconButton(
            tooltip: '行书签 (Ctrl+B)',
            iconSize: 18,
            icon: Icon(
                file.bookmarks.contains(file.controller.selection.baseIndex)
                    ? Icons.bookmark
                    : Icons.bookmark_border),
            onPressed: _toggleBookmarkAtCursor,
          ),
          IconButton(
            tooltip: _showBookmarks ? '隐藏书签列表' : '书签列表',
            iconSize: 18,
            isSelected: _showBookmarks,
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: () => setState(() => _showBookmarks = !_showBookmarks),
          ),
          IconButton(
            tooltip: _showMinimap ? '隐藏缩略图' : '显示缩略图',
            iconSize: 18,
            isSelected: _showMinimap,
            icon: const Icon(Icons.map_outlined),
            onPressed: () => setState(() => _showMinimap = !_showMinimap),
          ),
          IconButton(
            tooltip: '重新加载',
            iconSize: 18,
            icon: const Icon(Icons.refresh),
            onPressed: file.load,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: file.saving || !file.dirty ? null : _save,
            icon: file.saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save, size: 16),
            label: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _editor() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lang = file.language;
    return CodeEditor(
      controller: file.controller,
      scrollController: file.scroll,
      wordWrap: false,
      style: CodeEditorStyle(
        fontSize: _kFontSize,
        fontHeight: _kFontHeight,
        fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
        codeTheme: CodeHighlightTheme(
          languages: lang == null
              ? const {}
              : {lang.name: CodeHighlightThemeMode(mode: lang.mode)},
          theme: dark ? atomOneDarkTheme : vsTheme,
        ),
      ),
      indicatorBuilder:
          (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            DefaultCodeLineNumber(
                controller: editingController, notifier: notifier),
            DefaultCodeChunkIndicator(
                width: 18, controller: chunkController, notifier: notifier),
          ],
        );
      },
      findBuilder: (context, controller, readOnly) =>
          _FindPanel(controller: controller, readOnly: readOnly),
    );
  }

  Widget _statusBar() {
    final lang = file.language?.name ?? '纯文本';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      alignment: Alignment.centerLeft,
      child: Text(
        '${file.path}    ${file.controller.text.split('\n').length} 行    $lang    UTF-8',
        style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
      ),
    );
  }
}

/// 代码缩略图（minimap）：按行绘制细线，显示当前视口并支持点击跳转。
class _Minimap extends StatefulWidget {
  const _Minimap({super.key, required this.file});
  final EditorFile file;

  @override
  State<_Minimap> createState() => _MinimapState();
}

class _MinimapState extends State<_Minimap> {
  static const double _width = 84;

  ScrollController get _sc => widget.file.scroll.verticalScroller;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onChange);
    widget.file.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    _sc.removeListener(_onChange);
    widget.file.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _handleTap(double dy, double height) {
    if (!_sc.hasClients) return;
    final total = _sc.position.maxScrollExtent + _sc.position.viewportDimension;
    final frac = (dy / height).clamp(0.0, 1.0);
    final target = (frac * total - _sc.position.viewportDimension / 2)
        .clamp(0.0, _sc.position.maxScrollExtent);
    _sc.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = widget.file.controller.text.split('\n');
    return GestureDetector(
      onTapDown: (d) =>
          _handleTap(d.localPosition.dy, context.size?.height ?? 1),
      onVerticalDragUpdate: (d) =>
          _handleTap(d.localPosition.dy, context.size?.height ?? 1),
      child: Container(
        width: _width,
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          border: Border(left: BorderSide(color: cs.outlineVariant)),
        ),
        child: CustomPaint(
          painter: _MinimapPainter(
            lines: lines,
            bookmarks: widget.file.bookmarks,
            lineColor: cs.onSurfaceVariant.withValues(alpha: 0.45),
            bookmarkColor: cs.primary,
            viewportColor: cs.primary.withValues(alpha: 0.12),
            scroll: _sc.hasClients ? _sc.position : null,
          ),
          size: const Size(_width, double.infinity),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.lines,
    required this.bookmarks,
    required this.lineColor,
    required this.bookmarkColor,
    required this.viewportColor,
    required this.scroll,
  });

  final List<String> lines;
  final Set<int> bookmarks;
  final Color lineColor;
  final Color bookmarkColor;
  final Color viewportColor;
  final ScrollPosition? scroll;

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty) return;
    final double rowH = (size.height / lines.length).clamp(0.6, 3.0);
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = rowH * 0.6;
    const double left = 6;
    for (var i = 0; i < lines.length; i++) {
      final y = i * rowH;
      if (y > size.height) break;
      final len = lines[i].trimRight().length;
      if (len == 0) continue;
      final w = (len * 1.1).clamp(0.0, size.width - left - 6);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), linePaint);
    }
    final bmPaint = Paint()..color = bookmarkColor;
    for (final b in bookmarks) {
      if (b < 0 || b >= lines.length) continue;
      final y = b * rowH;
      canvas.drawRect(Rect.fromLTWH(0, y - 1, 3, rowH + 1), bmPaint);
    }
    final sp = scroll;
    if (sp != null) {
      final total = sp.maxScrollExtent + sp.viewportDimension;
      if (total > 0) {
        final top = (sp.pixels / total) * size.height;
        final h = (sp.viewportDimension / total) * size.height;
        canvas.drawRect(Rect.fromLTWH(0, top, size.width, h),
            Paint()..color = viewportColor);
        canvas.drawRect(
            Rect.fromLTWH(0, top, size.width, h),
            Paint()
              ..color = bookmarkColor.withValues(alpha: 0.4)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) => true;
}

/// 书签列表面板：显示所有行书签，点击跳转、可删除。
class _BookmarkPanel extends StatelessWidget {
  const _BookmarkPanel(
      {required this.file, required this.onJump, required this.onRemove});
  final EditorFile file;
  final ValueChanged<int> onJump;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = file.controller.text.split('\n');
    final marks = file.bookmarks.toList()..sort();
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(left: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Text('书签列表',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface)),
          ),
          const Divider(height: 1),
          Expanded(
            child: marks.isEmpty
                ? Center(
                    child: Text('暂无书签\n定位后按 Ctrl+B 添加',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)))
                : ListView.builder(
                    itemCount: marks.length,
                    itemBuilder: (context, i) {
                      final line = marks[i];
                      final text =
                          line < lines.length ? lines[line].trim() : '';
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading:
                            Icon(Icons.bookmark, size: 16, color: cs.primary),
                        title: Text('第 ${line + 1} 行',
                            style: const TextStyle(fontSize: 12.5)),
                        subtitle: text.isEmpty
                            ? null
                            : Text(text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 14),
                          onPressed: () => onRemove(line),
                        ),
                        onTap: () => onJump(line),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 简洁的查找/替换面板，接入 re_editor 的 CodeFindController。
class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<CodeFindValue?>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        final result = value.result;
        final info = result == null
            ? '无结果'
            : '${result.index + 1}/${result.matches.length}';
        return Material(
          color: cs.surfaceContainerHigh,
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: controller.findInputController,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '查找',
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        suffixText: info,
                        suffixStyle:
                            TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                      onSubmitted: (_) => controller.nextMatch(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '上一个',
                  iconSize: 18,
                  onPressed: controller.previousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: '下一个',
                  iconSize: 18,
                  onPressed: controller.nextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                IconButton(
                  tooltip: '关闭',
                  iconSize: 18,
                  onPressed: controller.close,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
