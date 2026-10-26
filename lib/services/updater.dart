import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ReleaseAsset {
  ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final String url;
  final int size;

  /// GitHub 提供的 SHA-256（十六进制小写），旧版 Release 可能没有。
  final String? sha256;

  factory ReleaseAsset.fromJson(Map<String, dynamic> j) {
    final digest = j['digest'] as String?;
    return ReleaseAsset(
      name: j['name'] as String,
      url: j['browser_download_url'] as String,
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: digest != null && digest.startsWith('sha256:')
          ? digest.substring(7).toLowerCase()
          : null,
    );
  }
}

class ReleaseInfo {
  ReleaseInfo({
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.assets,
    this.publishedAt,
  });

  final String tag;
  final String notes;
  final String pageUrl;
  final List<ReleaseAsset> assets;
  final DateTime? publishedAt;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  factory ReleaseInfo.fromJson(Map<String, dynamic> j) => ReleaseInfo(
    tag: j['tag_name'] as String,
    notes: (j['body'] as String?)?.trim() ?? '',
    pageUrl: j['html_url'] as String,
    assets: [
      for (final a in (j['assets'] as List? ?? const []))
        ReleaseAsset.fromJson(a as Map<String, dynamic>),
    ],
    publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
  );
}

class UpdateCancelled implements Exception {}

/// 从 GitHub Release 检查并下载新版本。
class Updater {
  static const repo = 'gunzi-666/ssh-restart';
  static const releasesUrl = 'https://github.com/$repo/releases';
  static const _exeName = 'ssh_restart.exe';

  static Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static Future<ReleaseInfo> fetchLatest() async {
    final http.Response r;
    try {
      r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'ssh-restart-updater',
            },
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw '连接 GitHub 超时，请检查网络后重试';
    } on SocketException catch (e) {
      throw '无法连接 GitHub：${e.message}';
    }
    if (r.statusCode == 404) throw '仓库还没有发布任何版本';
    if (r.statusCode == 403 || r.statusCode == 429) {
      throw 'GitHub 接口访问过于频繁，请稍后再试';
    }
    if (r.statusCode != 200) throw 'GitHub 返回错误：HTTP ${r.statusCode}';
    return ReleaseInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// a > b 返回正数，相等返回 0。只比较 `1.2.3` 形式的数字部分。
  static int compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .split(RegExp(r'[+-]'))
        .first
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  /// 当前平台对应的安装包。
  static ReleaseAsset? assetFor(ReleaseInfo r) {
    final String want;
    if (Platform.isWindows) {
      want = 'SSH-Restart-Windows.zip';
    } else if (Platform.isMacOS) {
      want = 'SSH-Restart-macOS.zip';
    } else if (Platform.isAndroid) {
      want = 'SSH-Restart-universal.apk';
    } else {
      return null;
    }
    for (final a in r.assets) {
      if (a.name == want) return a;
    }
    return null;
  }

  /// 能否下载后自动替换并重启（桌面端）。
  static bool get canSelfInstall => Platform.isWindows || Platform.isMacOS;

  /// 下载到临时目录，[onProgress] 回调已接收字节数和总字节数。
  /// 调用 [cancel] 的 complete 可中止下载。
  static Future<File> download(
    ReleaseAsset asset, {
    required void Function(int received, int total) onProgress,
    Future<void>? cancel,
  }) async {
    final dir = Directory(
      p.join((await getTemporaryDirectory()).path, 'ssh_restart_update'),
    );
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, asset.name));

    final client = http.Client();
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      client.close();
    });
    final out = file.openWrite();
    final hash = Sha256().newHashSink();
    try {
      final req = http.Request('GET', Uri.parse(asset.url))
        ..headers['User-Agent'] = 'ssh-restart-updater';
      final res = await client.send(req);
      if (res.statusCode != 200) throw '下载失败：HTTP ${res.statusCode}';
      final total = res.contentLength ?? asset.size;
      var received = 0;
      await for (final chunk in res.stream) {
        out.add(chunk);
        hash.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await out.close();
      hash.close();
      if (total > 0 && received != total) throw '下载不完整，请重试';
      final expected = asset.sha256;
      if (expected != null) {
        final got = (await hash.hash()).bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        if (got != expected) throw '安装包校验失败（SHA-256 不一致），已放弃更新';
      }
      return file;
    } catch (e) {
      await out.close().catchError((_) {});
      if (await file.exists()) await file.delete();
      if (cancelled) throw UpdateCancelled();
      if (e is http.ClientException || e is SocketException) {
        throw '下载中断：$e';
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 解压下载好的安装包，并启动一个在本程序退出后替换文件、重新打开的脚本。
  /// 返回后调用方应立即退出程序。
  static Future<void> prepareInstall(File zip) async {
    if (kDebugMode) throw '调试模式下不会替换程序文件，安装包已下载到：${zip.path}';
    final work = zip.parent;
    final extracted = Directory(p.join(work.path, 'new'));
    if (await extracted.exists()) await extracted.delete(recursive: true);
    if (Platform.isWindows) {
      await _prepareWindows(zip, work, extracted);
    } else if (Platform.isMacOS) {
      await _prepareMacOS(zip, work, extracted);
    } else {
      throw '当前平台不支持自动安装';
    }
  }

  static Future<void> _prepareWindows(
    File zip,
    Directory work,
    Directory extracted,
  ) async {
    final installDir = p.dirname(Platform.resolvedExecutable);
    final probe = File(p.join(installDir, '.ssh_restart_write_test'));
    try {
      await probe.writeAsString('');
      await probe.delete();
    } catch (_) {
      throw '程序所在目录没有写入权限（$installDir），请手动下载安装包覆盖';
    }

    await extractFileToDisk(zip.path, extracted.path);
    if (!await File(p.join(extracted.path, _exeName)).exists()) {
      throw '安装包内容不正确：没有找到 $_exeName';
    }

    // 与 v2rayN 的升级方式相同：由独立进程在主程序退出后覆盖文件。这里直接用新版本的
    // 可执行文件充当升级程序，不借助任何脚本。
    final log = p.join(work.path, 'install.log');
    await File(log).writeAsString('');
    await Process.start(
      p.join(extracted.path, _exeName),
      [applyFlag, installDir, log],
      mode: ProcessStartMode.detached,
      workingDirectory: extracted.path,
    );
  }

  static const applyFlag = '--apply-update';

  /// 以升级模式启动时（`ssh_restart.exe --apply-update <安装目录> <日志>`）执行覆盖、
  /// 打开新版本并结束进程；否则返回 false。必须在读取任何本地数据之前调用。
  static Future<bool> runApplyIfRequested(List<String> args) async {
    final i = args.indexOf(applyFlag);
    if (i < 0 || i + 2 >= args.length || !Platform.isWindows) return false;
    final dst = args[i + 1];
    final log = File(args[i + 2]);
    void write(String m) {
      try {
        final t = DateTime.now().toIso8601String().substring(11, 19);
        log.writeAsStringSync('$t $m\n', mode: FileMode.append);
      } catch (_) {}
    }

    final src = p.dirname(Platform.resolvedExecutable);
    var ok = false;
    try {
      ok = await applyUpdate(src: src, dst: dst, log: write);
    } catch (e) {
      write('替换失败：$e');
    }
    try {
      await Process.start(
        p.join(dst, _exeName),
        const [],
        mode: ProcessStartMode.detached,
        workingDirectory: dst,
      );
      write(ok ? '已启动新版本' : '替换未完成，已重新打开原程序');
    } catch (e) {
      write('启动程序失败：$e');
    }
    exit(0);
  }

  /// 等待 [dst] 中的旧程序退出（可执行文件可写），再把 [src] 的全部文件覆盖过去。
  @visibleForTesting
  static Future<bool> applyUpdate({
    required String src,
    required String dst,
    required void Function(String) log,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (p.equals(src, dst)) throw '源目录与安装目录相同';
    final target = File(p.join(dst, _exeName));
    final deadline = DateTime.now().add(timeout);
    log('等待原程序退出');
    while (await target.exists()) {
      try {
        final f = await target.open(mode: FileMode.append);
        await f.close();
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          log('等待超时：原程序仍在运行');
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }

    final files = Directory(
      src,
    ).listSync(recursive: true, followLinks: false).whereType<File>().toList();
    for (final f in files) {
      final out = File(p.join(dst, p.relative(f.path, from: src)));
      for (var attempt = 1; ; attempt++) {
        try {
          await out.parent.create(recursive: true);
          await f.copy(out.path);
          break;
        } on FileSystemException catch (e) {
          if (attempt >= 20) {
            log('复制失败：${out.path}：${e.message}');
            return false;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    log('文件替换完成（${files.length} 个文件）');
    return true;
  }

  /// 正常启动时清理上次更新留下的安装包与解压目录（保留 install.log 便于排查）。
  static Future<void> cleanupLeftovers() async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'ssh_restart_update'),
      );
      if (!await dir.exists()) return;
      if (p.isWithin(dir.path, Platform.resolvedExecutable)) return;
      // 升级进程可能还在退出，稍等再删。
      await Future<void>.delayed(const Duration(seconds: 5));
      await for (final e in dir.list()) {
        if (p.basename(e.path) == 'install.log') continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _prepareMacOS(
    File zip,
    Directory work,
    Directory extracted,
  ) async {
    // .../X.app/Contents/MacOS/ssh_restart
    final appPath = p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable)));
    if (!appPath.endsWith('.app')) throw '无法确定程序位置：$appPath';
    try {
      final probe = File(p.join(p.dirname(appPath), '.ssh_restart_write_test'));
      await probe.writeAsString('');
      await probe.delete();
    } catch (_) {
      throw '程序所在目录没有写入权限（${p.dirname(appPath)}），请手动下载安装包覆盖';
    }

    await extracted.create(recursive: true);
    final r = await Process.run('ditto', ['-x', '-k', zip.path, extracted.path]);
    if (r.exitCode != 0) throw '解压失败：${r.stderr}';
    final newApp = extracted
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('.app'))
        .firstOrNull;
    if (newApp == null) throw '安装包内容不正确：没有找到 .app';

    String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
    final script = File(p.join(work.path, 'install.sh'));
    await script.writeAsString('''
#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 0.5; done
bak=${q('$appPath.old')}
rm -rf "\$bak"
if mv ${q(appPath)} "\$bak"; then
  if mv ${q(newApp.path)} ${q(appPath)}; then
    rm -rf "\$bak"
    xattr -dr com.apple.quarantine ${q(appPath)} 2>/dev/null
  else
    mv "\$bak" ${q(appPath)}
  fi
fi
open ${q(appPath)}
''');
    await Process.start('/bin/sh', [
      script.path,
    ], mode: ProcessStartMode.detached);
  }
}
