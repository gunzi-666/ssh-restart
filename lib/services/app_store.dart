import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/session_config.dart';
import 'sqlite_store.dart';

/// 应用的全部持久化数据：会话、分组、快捷命令、历史命令、主机指纹与设置。
class AppStore extends ChangeNotifier {
  final List<SessionConfig> _sessions = [];
  final List<SessionGroup> _groups = [];
  final List<QuickCommand> _quickCommands = [];
  final List<String> history = [];
  final Map<String, String> knownHosts = {};
  AppSettings settings = AppSettings();

  late Directory _dir;
  SqliteStore? _db;
  Timer? _saveTimer;

  /// 启用了启动密码且尚未验证时为 true，界面应显示解锁页。
  bool locked = false;
  final Completer<void> _unlocked = Completer<void>();
  Future<void> get whenUnlocked => _unlocked.future;

  /// 会话、分组或快捷命令发生变化时触发，用于“数据变化后自动上传备份”。
  final StreamController<void> _dataChanged = StreamController.broadcast();
  Stream<void> get onDataChanged => _dataChanged.stream;

  List<SessionConfig> get sessions =>
      _sessions.where((s) => !s.deleted).toList(growable: false);
  List<SessionGroup> get groups =>
      _groups.where((g) => !g.deleted).toList(growable: false);
  /// 按拖拽顺序排列；顺序相同时保持原有先后。
  List<QuickCommand> get quickCommands {
    final list = [
      for (final (i, q) in _quickCommands.indexed)
        if (!q.deleted) (i, q),
    ]..sort((a, b) {
        final c = a.$2.order.compareTo(b.$2.order);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, q) in list) q];
  }

  /// 快捷命令分组：先按保存的拖拽顺序，其余按命令中首次出现的先后。
  List<String> get quickCommandGroups {
    final present = {for (final q in quickCommands) q.group};
    return [
      for (final g in settings.quickGroupOrder)
        if (present.remove(g)) g,
      ...present,
    ];
  }

  int get nextQuickOrder => _quickCommands
      .where((q) => !q.deleted)
      .fold(-1, (m, q) => max(m, q.order)) + 1;

  List<SessionConfig> get allSessionsRaw => _sessions;
  List<SessionGroup> get allGroupsRaw => _groups;
  List<QuickCommand> get allQuickCommandsRaw => _quickCommands;

  static Future<Directory> dataDir() async {
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (Platform.isMacOS) {
      migrateFromSandbox(dir, Platform.environment['HOME']);
    }
    return dir;
  }

  /// 早期 macOS 版本启用了 App 沙盒，数据位于 ~/Library/Containers 下；
  /// 关闭沙盒后首次启动时，若新目录还没有数据，则把旧数据复制过来（不删除原文件）。
  @visibleForTesting
  static void migrateFromSandbox(Directory dir, String? home) {
    if (home == null) return;
    final bundleId = p.basename(dir.path);
    final old = Directory(p.join(home, 'Library', 'Containers', bundleId, 'Data',
        'Library', 'Application Support', bundleId));
    if (p.equals(old.path, dir.path) || !old.existsSync()) return;
    bool hasData(Directory d) =>
        File(p.join(d.path, dbName)).existsSync() ||
        File(p.join(d.path, _legacyName)).existsSync();
    if (hasData(dir) || !hasData(old)) return;
    try {
      for (final e in old.listSync(recursive: true, followLinks: false)) {
        final target = p.join(dir.path, p.relative(e.path, from: old.path));
        if (e is Directory) {
          Directory(target).createSync(recursive: true);
        } else if (e is File) {
          Directory(p.dirname(target)).createSync(recursive: true);
          e.copySync(target);
        }
      }
    } catch (e) {
      debugPrint('迁移沙盒数据失败：$e');
    }
  }

  static const dbName = 'ssh_restart.db';
  static const _legacyName = 'data.json';

  Future<void> load() async {
    _dir = await dataDir();
    await loadFrom(_dir);
    locked = hasStartupPassword;
    if (!locked) _unlocked.complete();
  }

  /// 从指定目录加载（便于测试）。首次运行新版时把旧版 data.json 迁移进数据库。
  Future<void> loadFrom(Directory dir) async {
    _dir = dir;
    final db = _db = SqliteStore.open(p.join(dir.path, dbName));
    if (db.meta('initialized') != null) {
      _loadFromDb(db);
      return;
    }
    final legacy = File(p.join(dir.path, _legacyName));
    if (legacy.existsSync()) {
      try {
        _applyJson(
          jsonDecode(await legacy.readAsString()) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('读取旧版 data.json 失败，保留原文件: $e');
        _loadFromDb(db);
        return;
      }
      for (final t in SqliteStore.tables) {
        db.read(t);
      }
      _writeAll(db);
      if (_verify(db)) {
        db.setMeta('initialized', '${nowMs()}');
        db.setMeta('migratedFrom', _legacyName);
        for (final name in [_legacyName, '$_legacyName.tmp']) {
          final f = File(p.join(dir.path, name));
          if (f.existsSync()) await f.delete();
        }
      } else {
        debugPrint('迁移校验未通过，保留 data.json，下次启动重试');
      }
      return;
    }
    db.setMeta('initialized', '${nowMs()}');
  }

  void _applyJson(Map<String, dynamic> j) {
    _sessions
      ..clear()
      ..addAll(
        ((j['sessions'] as List?) ?? []).map(
          (e) => SessionConfig.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
    _groups
      ..clear()
      ..addAll(
        ((j['groups'] as List?) ?? []).map(
          (e) => SessionGroup.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
    _quickCommands
      ..clear()
      ..addAll(
        ((j['quickCommands'] as List?) ?? []).map(
          (e) => QuickCommand.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
    history
      ..clear()
      ..addAll(((j['history'] as List?) ?? []).cast<String>());
    knownHosts
      ..clear()
      ..addAll(Map<String, String>.from(j['knownHosts'] as Map? ?? {}));
    settings = AppSettings.fromJson(
      Map<String, dynamic>.from(j['settings'] as Map? ?? {}),
    );
  }

  void _loadFromDb(SqliteStore db) {
    Map<String, dynamic> dec(String s) =>
        Map<String, dynamic>.from(jsonDecode(s) as Map);
    _sessions
      ..clear()
      ..addAll(
        db
            .read(SqliteStore.sessions)
            .values
            .map((s) => SessionConfig.fromJson(dec(s))),
      );
    _groups
      ..clear()
      ..addAll(
        db
            .read(SqliteStore.groups)
            .values
            .map((s) => SessionGroup.fromJson(dec(s))),
      );
    _quickCommands
      ..clear()
      ..addAll(
        db
            .read(SqliteStore.quickCommands)
            .values
            .map((s) => QuickCommand.fromJson(dec(s))),
      );
    final kv = db.read(SqliteStore.kv);
    history
      ..clear()
      ..addAll(((jsonDecode(kv['history'] ?? '[]') as List)).cast<String>());
    knownHosts
      ..clear()
      ..addAll(
        Map<String, String>.from(jsonDecode(kv['knownHosts'] ?? '{}') as Map),
      );
    settings = AppSettings.fromJson(dec(kv['settings'] ?? '{}'));
  }

  void _writeAll(SqliteStore db) {
    db.sync(SqliteStore.sessions, {
      for (final s in _sessions) s.id: jsonEncode(s.toJson()),
    });
    db.sync(SqliteStore.groups, {
      for (final g in _groups) g.id: jsonEncode(g.toJson()),
    });
    db.sync(SqliteStore.quickCommands, {
      for (final q in _quickCommands) q.id: jsonEncode(q.toJson()),
    });
    db.sync(SqliteStore.kv, {
      'settings': jsonEncode(settings.toJson()),
      'history': jsonEncode(history),
      'knownHosts': jsonEncode(knownHosts),
    });
  }

  bool _verify(SqliteStore db) =>
      db.count(SqliteStore.sessions) == _sessions.length &&
      db.count(SqliteStore.groups) == _groups.length &&
      db.count(SqliteStore.quickCommands) == _quickCommands.length &&
      db.count(SqliteStore.kv) == 3;

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    final db = _db;
    if (db == null) return;
    _writeAll(db);
  }

  /// 退出前调用：写入所有未保存的修改并关闭数据库。
  void shutdown() {
    _saveTimer?.cancel();
    final db = _db;
    if (db == null) return;
    _db = null;
    try {
      _writeAll(db);
    } finally {
      db.close();
    }
  }

  // ---------------- 启动密码 ----------------
  static const _pwIterations = 150000;

  bool get hasStartupPassword => _db?.meta('lockHash') != null;

  Future<String> _hashPassword(
    String pw,
    List<int> salt,
    int iterations,
  ) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(password: pw, nonce: salt);
    return base64Encode(await key.extractBytes());
  }

  Future<void> setStartupPassword(String pw) async {
    final r = Random.secure();
    final salt = List<int>.generate(16, (_) => r.nextInt(256));
    final hash = await _hashPassword(pw, salt, _pwIterations);
    final db = _db!;
    db.setMeta('lockSalt', base64Encode(salt));
    db.setMeta('lockIterations', '$_pwIterations');
    db.setMeta('lockHash', hash);
    notifyListeners();
  }

  Future<bool> verifyStartupPassword(String pw) async {
    final db = _db;
    final hash = db?.meta('lockHash');
    if (db == null || hash == null) return true;
    final salt = base64Decode(db.meta('lockSalt') ?? '');
    final it = int.tryParse(db.meta('lockIterations') ?? '') ?? _pwIterations;
    return await _hashPassword(pw, salt, it) == hash;
  }

  void clearStartupPassword() {
    final db = _db;
    if (db == null) return;
    for (final k in ['lockHash', 'lockSalt', 'lockIterations']) {
      db.deleteMeta(k);
    }
    notifyListeners();
  }

  Future<bool> unlock(String pw) async {
    if (!await verifyStartupPassword(pw)) return false;
    locked = false;
    if (!_unlocked.isCompleted) _unlocked.complete();
    notifyListeners();
    return true;
  }

  // ---------------- 清除所有数据 ----------------
  /// 删除数据目录下的全部文件（数据库、旧版 data.json 等），并恢复为全新状态。
  Future<void> clearAllData() async {
    _saveTimer?.cancel();
    _db?.close();
    _db = null;
    if (_dir.existsSync()) {
      for (final e in _dir.listSync()) {
        try {
          await e.delete(recursive: true);
        } catch (err) {
          debugPrint('删除失败 ${e.path}: $err');
        }
      }
    }
    _sessions.clear();
    _groups.clear();
    _quickCommands.clear();
    history.clear();
    knownHosts.clear();
    settings = AppSettings();
    _db = SqliteStore.open(p.join(_dir.path, dbName))
      ..setMeta('initialized', '${nowMs()}');
    locked = false;
    if (!_unlocked.isCompleted) _unlocked.complete();
    notifyListeners();
    _dataChanged.add(null);
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

  void deleteSession(String id) => deleteSessions([id]);

  void deleteSessions(Iterable<String> ids) {
    final set = ids.toSet();
    var n = 0;
    for (final s in _sessions) {
      if (s.deleted || !set.contains(s.id)) continue;
      s.deleted = true;
      s.updatedAt = nowMs();
      s.password = '';
      s.privateKey = '';
      s.passphrase = '';
      n++;
    }
    if (n > 0) _changed();
  }

  /// 找出连接配置完全相同（含名称、认证信息、备注）的服务器；每组第一项为建议保留的一台。
  List<List<SessionConfig>> findDuplicateSessions() {
    final jumps = {for (final s in sessions) ?s.jumpSessionId};
    final byKey = <String, List<SessionConfig>>{};
    for (final s in sessions) {
      byKey.putIfAbsent(s.duplicateKey, () => []).add(s);
    }
    int rank(SessionConfig a, SessionConfig b) {
      for (final c in [
        (jumps.contains(b.id) ? 1 : 0) - (jumps.contains(a.id) ? 1 : 0),
        (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0),
        b.lastConnectedAt.compareTo(a.lastConnectedAt),
        b.updatedAt.compareTo(a.updatedAt),
      ]) {
        if (c != 0) return c;
      }
      return 0;
    }

    return [
      for (final list in byKey.values)
        if (list.length > 1) list..sort(rank),
    ];
  }

  /// 删除每组除第一项之外的服务器，并把指向被删项的跳板机改为保留项。
  int removeDuplicateSessions(List<List<SessionConfig>> groups) {
    final replace = <String, String>{};
    for (final g in groups) {
      final keep = g.first;
      for (final s in g.skip(1)) {
        replace[s.id] = keep.id;
        if (s.favorite) keep.favorite = true;
      }
    }
    if (replace.isEmpty) return 0;
    for (final s in sessions) {
      final to = replace[s.jumpSessionId];
      if (to != null && !replace.containsKey(s.id) && to != s.id) {
        s.jumpSessionId = to;
        s.updatedAt = nowMs();
      }
    }
    for (final g in groups) {
      g.first.updatedAt = nowMs();
    }
    deleteSessions(replace.keys);
    return replace.length;
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
      q.order = nextQuickOrder;
      _quickCommands.add(q);
    }
    _changed();
  }

  /// 按树状视图拖拽后的结果整体写回：[groups] 为分组顺序，[items] 为（命令 id, 所属分组）的先后。
  void applyQuickLayout(List<String> groups, List<(String, String)> items) {
    final byId = {for (final q in _quickCommands) q.id: q};
    final now = nowMs();
    for (final (i, (id, group)) in items.indexed) {
      final q = byId[id];
      if (q == null || (q.order == i && q.group == group)) continue;
      q
        ..order = i
        ..group = group
        ..updatedAt = now;
    }
    settings.quickGroupOrder = [...groups];
    _changed();
  }

  void reorderQuickGroups(List<String> groups) {
    settings.quickGroupOrder = [...groups];
    _changed();
  }

  void renameQuickGroup(String from, String to) {
    final now = nowMs();
    for (final q in _quickCommands) {
      if (!q.deleted && q.group == from) {
        q
          ..group = to
          ..updatedAt = now;
      }
    }
    final order = settings.quickGroupOrder;
    if (order.contains(from)) {
      order.remove(to);
      order[order.indexOf(from)] = to;
    }
    _changed();
  }

  void deleteQuickGroup(String group) {
    final now = nowMs();
    for (final q in _quickCommands) {
      if (!q.deleted && q.group == group) {
        q
          ..deleted = true
          ..updatedAt = now;
      }
    }
    settings.quickGroupOrder.remove(group);
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

  /// 只保存、不通知界面刷新，用于窗口尺寸等与界面无关的状态。
  void persistSettings(void Function(AppSettings s) fn) {
    fn(settings);
    _scheduleSave();
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
