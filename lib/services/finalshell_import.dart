import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/desede_engine.dart';
import 'package:pointycastle/digests/md5.dart';

import '../models/session_config.dart';

/// FinalShell 连接配置导入：解析 conn 目录下的 *_connect_config.json、
/// 分组配置以及 config.json 中的私钥，并解密 FinalShell 加密保存的密码。
class FinalShellImportResult {
  final List<SessionGroup> groups = [];
  final List<SessionConfig> sessions = [];
  int skippedOther = 0;
  int passwordOk = 0;
  int passwordFailed = 0;
  int keyMatched = 0;
  int keyMissing = 0;
}

class FinalShellImporter {
  /// 本机 FinalShell 的默认数据目录（存在时返回）。
  static String? detectDefaultDir() {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final candidates = <String>[
      if (Platform.isWindows) ...[
        if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\finalshell',
        '$home\\AppData\\Local\\finalshell',
        r'C:\Program Files\finalshell',
        r'D:\finalshell',
      ],
      if (Platform.isMacOS) '$home/Library/FinalShell',
      if (Platform.isLinux) '$home/.finalshell',
    ];
    for (final c in candidates) {
      if (Directory('$c${Platform.pathSeparator}conn').existsSync()) return c;
    }
    return null;
  }

  static Future<FinalShellImportResult> fromDirectory(String path) async {
    final root = Directory(path);
    final entries = <_Entry>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.toLowerCase().endsWith('.json')) continue;
      final rel = e.path.substring(root.path.length).replaceAll('\\', '/');
      try {
        entries.add(_Entry(rel, await e.readAsString()));
      } catch (_) {}
    }
    final parent = root.parent;
    if (root.path.toLowerCase().endsWith('conn')) {
      final cfg = File('${parent.path}${Platform.pathSeparator}config.json');
      if (cfg.existsSync()) {
        entries.add(_Entry('/config.json', await cfg.readAsString()));
      }
    }
    return _parse(entries);
  }

  static FinalShellImportResult fromFiles(Map<String, Uint8List> files) {
    final entries = <_Entry>[];
    for (final MapEntry(key: name, value: bytes) in files.entries) {
      final lower = name.toLowerCase();
      if (lower.endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive) {
          if (!f.isFile || !f.name.toLowerCase().endsWith('.json')) continue;
          entries.add(_Entry('/${f.name.replaceAll('\\', '/')}',
              utf8.decode(f.readBytes() ?? const [], allowMalformed: true)));
        }
      } else if (lower.endsWith('.json')) {
        entries.add(
            _Entry('/$name', utf8.decode(bytes, allowMalformed: true)));
      }
    }
    return _parse(entries);
  }

  static FinalShellImportResult _parse(List<_Entry> entries) {
    final r = FinalShellImportResult();
    final folders = <String, Map<String, dynamic>>{};
    final conns = <(_Entry, Map<String, dynamic>)>[];
    final keys = <String, (String key, String pass)>{};

    for (final e in entries) {
      final Object? json;
      try {
        json = jsonDecode(e.text);
      } catch (_) {
        continue;
      }
      if (json is! Map) continue;
      final m = Map<String, dynamic>.from(json);
      final base = e.path.split('/').last.toLowerCase();
      if (m.containsKey('host')) {
        conns.add((e, m));
      } else if (base == 'config.json' || base.contains('config')) {
        _collectKeys(m, keys);
        if (base != 'config.json' && m['id'] is String && m['name'] is String) {
          folders[m['id'] as String] = m;
        }
      } else if (m['id'] is String && m['name'] is String) {
        folders[m['id'] as String] = m;
      }
    }

    final groupIds = <String, String>{};
    String? mapFolder(String? fsId, [Set<String>? seen]) {
      if (fsId == null || fsId.isEmpty || fsId == 'root') return null;
      final existing = groupIds[fsId];
      if (existing != null) return existing;
      final f = folders[fsId];
      if (f == null) return null;
      seen ??= {};
      if (!seen.add(fsId)) return null;
      final g = SessionGroup(
        name: (f['name'] as String).trim(),
        parentId: mapFolder(f['parent_id'] as String?, seen),
      );
      groupIds[fsId] = g.id;
      r.groups.add(g);
      return g.id;
    }

    final dirGroups = <String, String>{};
    String? mapDir(String relPath) {
      var segs = relPath.split('/').where((s) => s.isNotEmpty).toList();
      final ci = segs.lastIndexWhere((s) => s.toLowerCase() == 'conn');
      segs = segs.sublist(ci + 1, segs.length - 1);
      String? parent;
      var key = '';
      for (final s in segs) {
        key = '$key/$s';
        final named = folders[s]?['name'] as String?;
        parent = dirGroups[key] ??= () {
          final g = SessionGroup(name: named ?? s, parentId: parent);
          r.groups.add(g);
          return g.id;
        }();
      }
      return parent;
    }

    for (final (e, m) in conns) {
      final type = _int(m['conection_type'] ?? m['connection_type']);
      if (type != null && type != 100) {
        r.skippedOther++;
        continue;
      }
      final s = SessionConfig(
        name: (m['name'] as String? ?? '').trim(),
        host: (m['host'] as String? ?? '').trim(),
        port: _int(m['port']) ?? 22,
        username: (m['user_name'] ?? m['username'] ?? '') as String,
        description: (m['description'] as String? ?? '').trim(),
        charset: (m['terminal_encoding'] as String? ?? '')
                .toUpperCase()
                .contains('GBK')
            ? 'GBK'
            : 'UTF-8',
        createdAt: _int(m['create_time']),
      );
      s.groupId =
          mapFolder(m['parent_id'] as String?) ?? mapDir(e.path);

      final enc = m['password'] as String? ?? '';
      if (enc.isNotEmpty) {
        final p = decodePassword(enc);
        if (p != null) {
          s.password = p;
          r.passwordOk++;
        } else {
          r.passwordFailed++;
        }
      }
      if (_int(m['authentication_type']) == 2) {
        s.authType = AuthType.key;
        final k = keys[m['secret_key_id'] as String? ?? ''];
        if (k != null) {
          s.privateKey = k.$1;
          s.passphrase = k.$2;
          r.keyMatched++;
        } else {
          r.keyMissing++;
        }
      }
      r.sessions.add(s);
    }
    return r;
  }

  /// 在 config.json 中递归查找私钥条目（含 PEM 文本的对象）。
  static void _collectKeys(Object? node, Map<String, (String, String)> out) {
    if (node is Map) {
      final id = node['id'];
      String? pem;
      for (final v in node.values) {
        if (v is String && v.contains('-----BEGIN')) pem = v;
      }
      if (id is String && pem != null) {
        final raw = (node['password'] ?? node['passphrase'] ?? '') as Object;
        final pass = raw is String && raw.isNotEmpty
            ? (decodePassword(raw) ?? raw)
            : '';
        out[id] = (pem, pass);
      }
      for (final v in node.values) {
        _collectKeys(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectKeys(v, out);
      }
    }
  }

  static int? _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  /// 解密 FinalShell 保存的密码：前 8 字节为随机头，用于派生 DES 密钥。
  static String? decodePassword(String data) {
    try {
      final buf = base64.decode(data.trim());
      if (buf.length <= 8 || (buf.length - 8) % 8 != 0) return null;
      final head = [for (var i = 0; i < 8; i++) buf[i].toSigned(8)];
      final key = _deriveKey(head).sublist(0, 8);
      final des = DESedeEngine()
        ..init(false, KeyParameter(Uint8List.fromList([...key, ...key, ...key])));
      final body = buf.sublist(8);
      final out = Uint8List(body.length);
      for (var off = 0; off < body.length; off += 8) {
        des.processBlock(body, off, out, off);
      }
      final pad = out.last;
      if (pad < 1 || pad > 8 || pad > out.length) return null;
      for (var i = out.length - pad; i < out.length; i++) {
        if (out[i] != pad) return null;
      }
      return utf8.decode(out.sublist(0, out.length - pad),
          allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _deriveKey(List<int> h) {
    final ks = 3680984568597093857 ~/ _JavaRandom(h[5]).nextInt(127);
    final random = _JavaRandom(ks);
    for (var i = 0; i < h[0]; i++) {
      random.nextLong();
    }
    final r2 = _JavaRandom(random.nextLong());
    final ld = [
      h[4], r2.nextLong(), h[7], h[3], r2.nextLong(), h[1],
      random.nextLong(), h[2],
    ];
    final bd = ByteData(64);
    for (var i = 0; i < ld.length; i++) {
      bd.setInt64(i * 8, ld[i]);
    }
    return MD5Digest().process(bd.buffer.asUint8List());
  }
}

class _Entry {
  _Entry(this.path, this.text);
  final String path;
  final String text;
}

/// java.util.Random 的等价实现（48 位线性同余）。
class _JavaRandom {
  _JavaRandom(int seed) : _seed = (seed ^ _mult) & _mask;

  static const _mult = 0x5DEECE66D;
  static const _mask = (1 << 48) - 1;
  int _seed;

  int _next(int bits) {
    _seed = (_seed * _mult + 0xB) & _mask;
    return (_seed >> (48 - bits)).toSigned(32);
  }

  int nextInt(int bound) {
    if ((bound & -bound) == bound) {
      return ((bound * _next(31)) >> 31).toSigned(32);
    }
    int bits, val;
    do {
      bits = _next(31);
      val = bits % bound;
    } while ((bits - val + (bound - 1)).toSigned(32) < 0);
    return val;
  }

  int nextLong() => (_next(32) << 32) + _next(32);
}
