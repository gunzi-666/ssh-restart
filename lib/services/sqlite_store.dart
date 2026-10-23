import 'package:sqlite3/sqlite3.dart';

/// 本地 SQLite 存储：每类数据一张表，每行保存一条记录的 JSON。
/// 写入时与上次写入的内容比较，只更新有变化的行。
class SqliteStore {
  SqliteStore._(this._db) {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('PRAGMA synchronous=NORMAL;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      );
    ''');
    for (final t in tables) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS $t (
          id TEXT PRIMARY KEY,
          data TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        );
      ''');
    }
  }

  static SqliteStore open(String path) => SqliteStore._(sqlite3.open(path));
  static SqliteStore memory() => SqliteStore._(sqlite3.openInMemory());

  static const sessions = 'sessions';
  static const groups = 'session_groups';
  static const quickCommands = 'quick_commands';
  static const kv = 'kv';
  static const tables = [sessions, groups, quickCommands, kv];

  final Database _db;
  final Map<String, Map<String, String>> _written = {
    for (final t in tables) t: {},
  };

  String? meta(String k) {
    final r = _db.select('SELECT v FROM meta WHERE k = ?', [k]);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  void setMeta(String k, String v) => _db.execute(
    'INSERT INTO meta (k, v) VALUES (?, ?) '
    'ON CONFLICT(k) DO UPDATE SET v = excluded.v',
    [k, v],
  );

  void deleteMeta(String k) => _db.execute('DELETE FROM meta WHERE k = ?', [k]);

  /// 读取整张表，返回 id → JSON 文本。
  Map<String, String> read(String table) {
    final out = <String, String>{};
    for (final r in _db.select('SELECT id, data FROM $table ORDER BY rowid')) {
      out[r['id'] as String] = r['data'] as String;
    }
    _written[table] = Map.of(out);
    return out;
  }

  int count(String table) =>
      _db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;

  /// 把整张表同步为 [rows]：新增/变化的行写入，不再存在的行删除。返回写入行数。
  int sync(String table, Map<String, String> rows) {
    final last = _written[table]!;
    final changed = [
      for (final e in rows.entries)
        if (last[e.key] != e.value) e,
    ];
    final removed = [
      for (final id in last.keys)
        if (!rows.containsKey(id)) id,
    ];
    if (changed.isEmpty && removed.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN');
    try {
      if (changed.isNotEmpty) {
        final stmt = _db.prepare(
          'INSERT INTO $table (id, data, updated_at) VALUES (?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET data = excluded.data, '
          'updated_at = excluded.updated_at',
        );
        for (final e in changed) {
          stmt.execute([e.key, e.value, now]);
        }
        stmt.dispose();
      }
      for (final id in removed) {
        _db.execute('DELETE FROM $table WHERE id = ?', [id]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _written[table] = Map.of(rows);
    return changed.length + removed.length;
  }

  void close() => _db.dispose();
}
