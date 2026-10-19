import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/session_config.dart';

/// 应用的全部持久化数据：会话、分组、快捷命令、历史命令、主机指纹与设置。
class AppStore extends ChangeNotifier {
  final List<SessionConfig> _sessions = [];
  final List<SessionGroup> _groups = [];
  final List<QuickCommand> _quickCommands = [];
  final List<String> history = [];
  final Map<String, String> knownHosts = {};
  AppSettings settings = AppSettings();

  late File _file;
  Timer? _saveTimer;

  /// 会话、分组或快捷命令发生变化时触发，用于“数据变化后自动上传备份”。
  final StreamController<void> _dataChanged = StreamController.broadcast();
  Stream<void> get onDataChanged => _dataChanged.stream;

  List<SessionConfig> get sessions =>
      _sessions.where((s) => !s.deleted).toList(growable: false);
  List<SessionGroup> get groups =>
      _groups.where((g) => !g.deleted).toList(growable: false);
  List<QuickCommand> get quickCommands =>
      _quickCommands.where((q) => !q.deleted).toList(growable: false);

  List<SessionConfig> get allSessionsRaw => _sessions;
  List<SessionGroup> get allGroupsRaw => _groups;
  List<QuickCommand> get allQuickCommandsRaw => _quickCommands;

  static Future<Directory> dataDir() async {
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> load() async {
    final dir = await dataDir();
    _file = File(p.join(dir.path, 'data.json'));
    if (!_file.existsSync()) return;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      _sessions
        ..clear()
        ..addAll(((j['sessions'] as List?) ?? []).map(
            (e) => SessionConfig.fromJson(Map<String, dynamic>.from(e))));
      _groups
        ..clear()
        ..addAll(((j['groups'] as List?) ?? []).map(
            (e) => SessionGroup.fromJson(Map<String, dynamic>.from(e))));
      _quickCommands
        ..clear()
        ..addAll(((j['quickCommands'] as List?) ?? []).map(
            (e) => QuickCommand.fromJson(Map<String, dynamic>.from(e))));
      history
        ..clear()
        ..addAll(((j['history'] as List?) ?? []).cast<String>());
      knownHosts
        ..clear()
        ..addAll(Map<String, String>.from(j['knownHosts'] as Map? ?? {}));
      settings = AppSettings.fromJson(
          Map<String, dynamic>.from(j['settings'] as Map? ?? {}));
    } catch (e) {
      debugPrint('加载数据失败: $e');
      final backup = File('${_file.path}.broken');
      await _file.copy(backup.path);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    final data = {
      'version': 1,
      'sessions': _sessions.map((e) => e.toJson()).toList(),
      'groups': _groups.map((e) => e.toJson()).toList(),
      'quickCommands': _quickCommands.map((e) => e.toJson()).toList(),
      'history': history,
      'knownHosts': knownHosts,
      'settings': settings.toJson(),
    };
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    if (_file.existsSync()) await _file.delete();
    await tmp.rename(_file.path);
  }

  void _changed({bool data = true}) {
    notifyListeners();
    _scheduleSave();
    if (data) _dataChanged.add(null);
  }

  // ---------------- 会话 ----------------
  SessionConfig? sessionById(String? id) {
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id && !s.deleted) return s;
    }
    return null;
  }

  void upsertSession(SessionConfig s) {
    s.updatedAt = nowMs();
    final i = _sessions.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      _sessions[i] = s;
    } else {
      _sessions.add(s);
    }
    _changed();
  }

  void deleteSession(String id) {
    final s = _sessions.where((e) => e.id == id).firstOrNull;
    if (s == null) return;
    s.deleted = true;
    s.updatedAt = nowMs();
    s.password = '';
    s.privateKey = '';
    s.passphrase = '';
    _changed();
  }

  void toggleFavorite(String id) {
    final s = sessionById(id);
    if (s == null) return;
    s.favorite = !s.favorite;
    upsertSession(s);
  }

  void touchSession(String id) {
    final s = sessionById(id);
    if (s == null) return;
    s.lastConnectedAt = nowMs();
    _changed(data: false);
  }

  // ---------------- 分组 ----------------
  SessionGroup? groupById(String? id) {
    if (id == null) return null;
    for (final g in _groups) {
      if (g.id == id && !g.deleted) return g;
    }
    return null;
  }

  void upsertGroup(SessionGroup g) {
    g.updatedAt = nowMs();
    final i = _groups.indexWhere((e) => e.id == g.id);
    if (i >= 0) {
      _groups[i] = g;
    } else {
      _groups.add(g);
    }
    _changed();
  }

  /// 删除分组时，其下的子分组和会话移动到上级分组。
  void deleteGroup(String id) {
    final g = _groups.where((e) => e.id == id).firstOrNull;
    if (g == null) return;
    for (final s in sessions.where((s) => s.groupId == id)) {
      s.groupId = g.parentId;
      s.updatedAt = nowMs();
    }
    for (final c in groups.where((c) => c.parentId == id)) {
      c.parentId = g.parentId;
      c.updatedAt = nowMs();
    }
    g.deleted = true;
    g.updatedAt = nowMs();
    _changed();
  }

  // ---------------- 快捷命令 ----------------
  void upsertQuickCommand(QuickCommand q) {
    q.updatedAt = nowMs();
    final i = _quickCommands.indexWhere((e) => e.id == q.id);
    if (i >= 0) {
      _quickCommands[i] = q;
    } else {
      _quickCommands.add(q);
    }
    _changed();
  }

  void deleteQuickCommand(String id) {
    final q = _quickCommands.where((e) => e.id == id).firstOrNull;
    if (q == null) return;
    q.deleted = true;
    q.updatedAt = nowMs();
    _changed();
  }

  // ---------------- 历史命令 ----------------
  void addHistory(String cmd) {
    final c = cmd.trim();
    if (c.isEmpty) return;
    history.remove(c);
    history.insert(0, c);
    if (history.length > 1000) history.removeRange(1000, history.length);
    _changed(data: false);
  }

  void removeHistory(String cmd) {
    history.remove(cmd);
    _changed(data: false);
  }

  void clearHistory() {
    history.clear();
    _changed(data: false);
  }

  // ---------------- 主机指纹 ----------------
  void setKnownHost(String hostKey, String fingerprint) {
    knownHosts[hostKey] = fingerprint;
    _changed(data: false);
  }

  // ---------------- 设置 ----------------
  void updateSettings(void Function(AppSettings s) fn) {
    fn(settings);
    _changed(data: false);
  }

  // ---------------- 备份导入 ----------------
  /// 合并：同一 id 以更新时间较新的一方为准；删除标记也参与合并，保证多设备间删除能同步。
  void mergeBackup({
    required List<SessionConfig> sessions,
    required List<SessionGroup> groups,
    required List<QuickCommand> quickCommands,
    Map<String, dynamic>? portableSettings,
    bool replace = false,
  }) {
    if (replace) {
      _sessions
        ..clear()
        ..addAll(sessions);
      _groups
        ..clear()
        ..addAll(groups);
      _quickCommands
        ..clear()
        ..addAll(quickCommands);
    } else {
      for (final s in sessions) {
        final i = _sessions.indexWhere((e) => e.id == s.id);
        if (i < 0) {
          _sessions.add(s);
        } else if (s.updatedAt > _sessions[i].updatedAt) {
          s.lastConnectedAt = _sessions[i].lastConnectedAt;
          _sessions[i] = s;
        }
      }
      for (final g in groups) {
        final i = _groups.indexWhere((e) => e.id == g.id);
        if (i < 0) {
          _groups.add(g);
        } else if (g.updatedAt > _groups[i].updatedAt) {
          _groups[i] = g;
        }
      }
      for (final q in quickCommands) {
        final i = _quickCommands.indexWhere((e) => e.id == q.id);
        if (i < 0) {
          _quickCommands.add(q);
        } else if (q.updatedAt > _quickCommands[i].updatedAt) {
          _quickCommands[i] = q;
        }
      }
    }
    if (portableSettings != null) settings.applyPortable(portableSettings);
    notifyListeners();
    _scheduleSave();
  }
}
