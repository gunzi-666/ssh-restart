import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import 'app_style.dart';
import 'widgets/shad.dart';

const _folderColor = Color(0xFFE8A93A);
const _ungroupedKey = '__ungrouped__';

/// 外观与下拉框一致的会话选择框，点击后弹出可搜索的文件夹树。
class SessionPickerField extends StatelessWidget {
  const SessionPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.excludeId,
    this.title = '选择会话',
    this.noneLabel = '不使用',
  });

  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// 正在编辑的会话：它自己以及以它为跳板的会话不会出现在列表中。
  final String? excludeId;
  final String title;
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final store = context.watch<AppStore>();
    final s = store.sessionById(value);
    final radius = BorderRadius.circular(st.controlRadius);
    return LabeledField(
      label: label,
      child: Material(
        color: st.inputFill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: cs.outlineVariant),
        ),
        child: InkWell(
          borderRadius: radius,
          hoverColor: st.hover,
          onTap: () async {
            final r = await showSessionPicker(
              context,
              title: title,
              selectedId: s?.id,
              excludeId: excludeId,
              noneLabel: noneLabel,
            );
            if (r != null) onChanged(r.id);
          },
          child: SizedBox(
            height: st.controlHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Row(
                children: [
                  if (s != null) ...[
                    Icon(Icons.terminal_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: s?.displayName ?? noneLabel),
                          if (s != null)
                            TextSpan(
                              text: '   ${s.username}@${s.host}:${s.port}',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 12.5,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 返回 null 表示取消；返回的 id 为 null 表示选择了「不使用」。
Future<({String? id})?> showSessionPicker(
  BuildContext context, {
  required String title,
  String? selectedId,
  String? excludeId,
  String noneLabel = '不使用',
}) => showDialog<({String? id})>(
  context: context,
  builder: (_) => _SessionPicker(
    title: title,
    selectedId: selectedId,
    excludeId: excludeId,
    noneLabel: noneLabel,
  ),
);

class _SessionPicker extends StatefulWidget {
  const _SessionPicker({
    required this.title,
    required this.selectedId,
    required this.excludeId,
    required this.noneLabel,
  });

  final String title;
  final String? selectedId;
  final String? excludeId;
  final String noneLabel;

  @override
  State<_SessionPicker> createState() => _SessionPickerState();
}

class _Row {
  _Row.group(this.group, this.depth, this.count, this.open, {this.ungrouped = false})
    : session = null;
  _Row.session(this.session, this.depth)
    : group = null,
      count = 0,
      open = null,
      ungrouped = false;

  final SessionGroup? group;
  final SessionConfig? session;
  final int depth;
  final int count;
  final bool? open;
  final bool ungrouped;
}

class _SessionPickerState extends State<_SessionPicker> {
  final _query = TextEditingController();
  late Set<String> _expanded;

  AppStore get _store => context.read<AppStore>();

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _expanded = store.settings.expandedGroups.toSet();
    final sel = store.sessionById(widget.selectedId);
    if (sel != null) {
      var gid = store.groupById(sel.groupId)?.id;
      if (gid == null) _expanded.add(_ungroupedKey);
      for (var i = 0; gid != null && i < 10; i++) {
        _expanded.add(gid);
        gid = store.groupById(store.groupById(gid)?.parentId)?.id;
      }
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// 候选会话：SSH 类型，排除自身以及跳板链中包含自身的会话（避免循环）。
  bool _eligible(SessionConfig s) {
    if (s.type != SessionType.ssh) return false;
    final self = widget.excludeId;
    if (self == null) return true;
    String? id = s.id;
    for (var i = 0; id != null && i < 16; i++) {
      if (id == self) return false;
      id = _store.sessionById(id)?.jumpSessionId;
    }
    return true;
  }

  bool _matches(SessionConfig s, String q, Map<String, SessionGroup> groups) {
    if (q.isEmpty) return true;
    bool has(String? v) => v != null && v.toLowerCase().contains(q);
    if (has(s.displayName) ||
        has(s.host) ||
        has(s.username) ||
        has(s.description)) {
      return true;
    }
    var g = groups[s.groupId];
    for (var i = 0; g != null && i < 10; i++) {
      if (has(g.name)) return true;
      g = groups[g.parentId];
    }
    return false;
  }

  List<_Row> _rows() {
    final store = _store;
    final q = _query.text.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final groupMap = {for (final g in store.groups) g.id: g};
    final subGroups = <String?, List<SessionGroup>>{};
    for (final g in store.groups) {
      final parent = groupMap.containsKey(g.parentId) ? g.parentId : null;
      subGroups.putIfAbsent(parent, () => []).add(g);
    }
    for (final l in subGroups.values) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    final direct = <String?, List<SessionConfig>>{};
    for (final s in store.sessions) {
      if (!_eligible(s) || !_matches(s, q, groupMap)) continue;
      final gid = groupMap.containsKey(s.groupId) ? s.groupId : null;
      direct.putIfAbsent(gid, () => []).add(s);
    }
    for (final l in direct.values) {
      l.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final totals = <String, int>{};
    int total(String id, Set<String> path) {
      final cached = totals[id];
      if (cached != null) return cached;
      if (!path.add(id)) return 0;
      var n = direct[id]?.length ?? 0;
      for (final c in subGroups[id] ?? const <SessionGroup>[]) {
        n += total(c.id, path);
      }
      path.remove(id);
      return totals[id] = n;
    }

    final rows = <_Row>[];
    void addGroup(SessionGroup g, int depth, Set<String> path) {
      if (depth > 8 || !path.add(g.id)) return;
      final count = total(g.id, {});
      if (count > 0) {
        final open = searching || _expanded.contains(g.id);
        rows.add(_Row.group(g, depth, count, open));
        if (open) {
          for (final c in subGroups[g.id] ?? const <SessionGroup>[]) {
            addGroup(c, depth + 1, path);
          }
          for (final s in direct[g.id] ?? const <SessionConfig>[]) {
            rows.add(_Row.session(s, depth + 1));
          }
        }
      }
      path.remove(g.id);
    }

    for (final g in subGroups[null] ?? const <SessionGroup>[]) {
      addGroup(g, 0, {});
    }
    final ungrouped = direct[null] ?? const <SessionConfig>[];
    if (ungrouped.isNotEmpty) {
      final open = searching || _expanded.contains(_ungroupedKey);
      rows.add(_Row.group(null, 0, ungrouped.length, open, ungrouped: true));
      if (open) {
        for (final s in ungrouped) {
          rows.add(_Row.session(s, 1));
        }
      }
    }
    return rows;
  }

  void _toggle(String key) => setState(() {
    _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key);
  });

  void _pick(String? id) => Navigator.pop(context, (id: id));

  @override
  Widget build(BuildContext context) {
    context.watch<AppStore>();
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    final rows = _rows();
    final searching = _query.text.trim().isNotEmpty;
    final firstSession = rows.where((r) => r.session != null).firstOrNull;
    return AppDialog(
      title: widget.title,
      width: 520,
      actions: [
        AppButton(label: '取消', onPressed: () => Navigator.pop(context)),
      ],
      child: SizedBox(
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (firstSession != null) _pick(firstSession.session!.id);
              },
              decoration: InputDecoration(
                hintText: '搜索名称、地址、用户名、备注或分组',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: searching
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () => setState(_query.clear),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outlineVariant),
                  borderRadius: BorderRadius.circular(st.controlRadius),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    if (!searching)
                      _item(
                        icon: Icons.block_rounded,
                        label: widget.noneLabel,
                        selected: widget.selectedId == null,
                        onTap: () => _pick(null),
                      ),
                    for (final r in rows) _rowWidget(r, firstSession),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            searching ? '没有匹配的会话' : '没有可选的 SSH 会话',
                            style: TextStyle(color: st.muted),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (searching && firstSession != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '按 Enter 选择第一个结果',
                  style: TextStyle(fontSize: 12, color: st.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _rowWidget(_Row r, _Row? first) {
    final s = r.session;
    if (s != null) {
      return _item(
        icon: Icons.terminal_rounded,
        label: s.displayName,
        detail: '${s.username}@${s.host}:${s.port}',
        depth: r.depth,
        selected: s.id == widget.selectedId,
        hinted: identical(r, first) && _query.text.trim().isNotEmpty,
        onTap: () => _pick(s.id),
      );
    }
    final key = r.ungrouped ? _ungroupedKey : r.group!.id;
    return _item(
      icon: r.ungrouped
          ? Icons.folder_off_outlined
          : r.open == true
          ? Icons.folder_open_rounded
          : Icons.folder_rounded,
      iconColor: r.ungrouped ? null : _folderColor,
      label: r.ungrouped ? '未分组' : r.group!.name,
      count: r.count,
      depth: r.depth,
      chevron: r.open,
      onTap: _query.text.trim().isNotEmpty ? null : () => _toggle(key),
    );
  }

  Widget _item({
    required IconData icon,
    required String label,
    String? detail,
    Color? iconColor,
    int depth = 0,
    int? count,
    bool? chevron,
    bool selected = false,
    bool hinted = false,
    VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final st = AppStyle.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.12)
            : hinted
            ? st.hover
            : Colors.transparent,
        borderRadius: BorderRadius.circular(st.controlRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(st.controlRadius),
          hoverColor: st.hover,
          onTap: onTap,
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                SizedBox(width: 6 + depth * 18.0),
                SizedBox(
                  width: 18,
                  child: chevron == null
                      ? null
                      : Icon(
                          chevron
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.chevron_right_rounded,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                ),
                const SizedBox(width: 4),
                Icon(
                  icon,
                  size: 17,
                  color: iconColor ?? (selected ? cs.primary : cs.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: selected ? FontWeight.w600 : null,
                            color: selected ? cs.primary : cs.onSurface,
                          ),
                        ),
                        if (detail != null)
                          TextSpan(
                            text: '   $detail',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (count != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (selected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(Icons.check_rounded, size: 16, color: cs.primary),
                  ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
