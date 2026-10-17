import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/session_config.dart';
import 'app_store.dart';
import 'backup_crypto.dart';
import 'gdrive_service.dart';

class ImportResult {
  final int sessions;
  final int groups;
  final int quickCommands;
  ImportResult(this.sessions, this.groups, this.quickCommands);
  @override
  String toString() => '会话 $sessions 个，分组 $groups 个，快捷命令 $quickCommands 条';
}

/// 负责加密备份的生成与导入，以及谷歌云盘的定时上传和启动时自动导入。
class BackupManager extends ChangeNotifier {
  BackupManager(this.store) : drive = GDriveService(store);

  final AppStore store;
  final GDriveService drive;

  bool busy = false;
  String status = '';
  Timer? _scheduleTimer;
  Timer? _changeDebounce;
  StreamSubscription? _changeSub;

  String get _key => store.settings.backupKey;

  void start() {
    _scheduleTimer?.cancel();
    _scheduleTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _checkSchedule());
    _changeSub?.cancel();
    _changeSub = store.onDataChanged.listen((_) {
      if (!store.settings.gdriveUploadOnChange) return;
      _changeDebounce?.cancel();
      _changeDebounce = Timer(const Duration(seconds: 30), () {
        uploadToDrive(silent: true);
      });
    });
    Future.delayed(const Duration(seconds: 3), () async {
      if (store.settings.gdriveAutoImport) await autoImportFromDrive();
      await _checkSchedule();
    });
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _changeDebounce?.cancel();
    _changeSub?.cancel();
    super.dispose();
  }

  void _setStatus(String s, {bool? isBusy}) {
    status = s;
    if (isBusy != null) busy = isBusy;
    notifyListeners();
  }

  Map<String, dynamic> buildPayload() => {
        'app': 'ssh-restart',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'device': Platform.operatingSystem,
        'sessions': store.allSessionsRaw.map((e) => e.toJson()).toList(),
        'groups': store.allGroupsRaw.map((e) => e.toJson()).toList(),
        'quickCommands':
            store.allQuickCommandsRaw.map((e) => e.toJson()).toList(),
        'settings': store.settings.toPortableJson(),
      };

  Future<String> exportEncrypted([String? key]) =>
      BackupCrypto.encrypt(buildPayload(), key ?? _key);

  Future<ImportResult> importEncrypted(
    String text, {
    String? key,
    bool replace = false,
    bool includeSettings = true,
  }) async {
    final payload = await BackupCrypto.decrypt(text, key ?? _key);
    final sessions = ((payload['sessions'] as List?) ?? [])
        .map((e) => SessionConfig.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final groups = ((payload['groups'] as List?) ?? [])
        .map((e) => SessionGroup.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final cmds = ((payload['quickCommands'] as List?) ?? [])
        .map((e) => QuickCommand.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    store.mergeBackup(
      sessions: sessions,
      groups: groups,
      quickCommands: cmds,
      portableSettings: includeSettings
          ? Map<String, dynamic>.from(payload['settings'] as Map? ?? {})
          : null,
      replace: replace,
    );
    return ImportResult(
      sessions.where((s) => !s.deleted).length,
      groups.where((g) => !g.deleted).length,
      cmds.where((c) => !c.deleted).length,
    );
  }

  Uint8List encodeFile(String text) => Uint8List.fromList(utf8.encode(text));

  String fileName() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ssh-restart-backup-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
  }

  // ---------------- 谷歌云盘 ----------------
  Future<bool> uploadToDrive({bool silent = false}) async {
    if (busy) return false;
    if (_key.isEmpty) {
      if (!silent) _setStatus('请先设置加密密钥');
      return false;
    }
    if (!drive.authorized) {
      if (!silent) _setStatus('请先授权谷歌云盘');
      return false;
    }
    _setStatus('正在上传备份…', isBusy: true);
    try {
      final text = await exportEncrypted();
      final f = await drive.upload(text, fileName());
      store.updateSettings((s) {
        s.lastUploadAt = nowMs();
        s.lastImportedRemoteId = f.id;
        s.lastImportedRemoteTime = f.modified.millisecondsSinceEpoch;
      });
      await drive.prune(store.settings.gdriveKeepCount);
      _setStatus('上传成功：${f.name}', isBusy: false);
      return true;
    } catch (e) {
      _setStatus('上传失败：$e', isBusy: false);
      return false;
    }
  }

  Future<ImportResult?> importFromDrive(String fileId,
      {bool replace = false, DateTime? modified}) async {
    if (busy) return null;
    _setStatus('正在下载备份…', isBusy: true);
    try {
      final text = await drive.download(fileId);
      final r = await importEncrypted(text, replace: replace);
      store.updateSettings((s) {
        s.lastImportedRemoteId = fileId;
        if (modified != null) {
          s.lastImportedRemoteTime = modified.millisecondsSinceEpoch;
        }
      });
      _setStatus('导入成功：$r', isBusy: false);
      return r;
    } catch (e) {
      _setStatus('导入失败：$e', isBusy: false);
      rethrow;
    }
  }

  /// 云盘上有比上次导入/上传更新的备份时，自动以合并方式导入。
  Future<void> autoImportFromDrive() async {
    if (_key.isEmpty || !drive.authorized || busy) return;
    try {
      final files = await drive.list();
      if (files.isEmpty) return;
      final latest = files.first;
      if (latest.id == store.settings.lastImportedRemoteId) return;
      if (latest.modified.millisecondsSinceEpoch <=
          store.settings.lastImportedRemoteTime) {
        return;
      }
      await importFromDrive(latest.id, modified: latest.modified);
    } catch (e) {
      _setStatus('自动导入失败：$e', isBusy: false);
    }
  }

  Future<void> _checkSchedule() async {
    final s = store.settings;
    if (!s.gdriveAutoUpload || s.gdriveAutoUploadHours <= 0) return;
    final due = s.lastUploadAt + s.gdriveAutoUploadHours * 3600 * 1000;
    if (nowMs() >= due) await uploadToDrive(silent: true);
  }
}
