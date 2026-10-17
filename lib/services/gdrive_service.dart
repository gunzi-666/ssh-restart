import 'dart:async';
import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_store.dart';

class GDriveBackupFile {
  final String id;
  final String name;
  final DateTime modified;
  final int size;
  GDriveBackupFile(this.id, this.name, this.modified, this.size);
}

/// 通过用户自己在 Google Cloud Console 创建的 OAuth 客户端访问谷歌云盘。
/// 只申请 drive.file 权限：只能看到本软件创建的文件，其他设备使用同一个客户端 ID 授权即可读取。
class GDriveService {
  GDriveService(this.store);

  final AppStore store;
  static const folderName = 'SSH-Restart-Backup';
  static const _scopes = [drive.DriveApi.driveFileScope];

  AutoRefreshingAuthClient? _client;
  StreamSubscription? _credSub;
  String? _folderId;

  bool get configured => store.settings.gdriveClientId.trim().isNotEmpty;
  bool get authorized => store.settings.gdriveCredentials.isNotEmpty;

  ClientId get _clientId {
    final secret = store.settings.gdriveClientSecret.trim();
    return ClientId(
      store.settings.gdriveClientId.trim(),
      secret.isEmpty ? null : secret,
    );
  }

  void _attach(AutoRefreshingAuthClient client) {
    _credSub?.cancel();
    _client?.close();
    _client = client;
    _folderId = null;
    _saveCredentials(client.credentials);
    _credSub = client.credentialUpdates.listen(_saveCredentials);
  }

  void _saveCredentials(AccessCredentials c) {
    store.updateSettings((s) => s.gdriveCredentials = jsonEncode(c.toJson()));
  }

  /// 打开系统浏览器完成授权，回调走本机回环地址，因此 OAuth 客户端类型需选“桌面应用”。
  Future<String> authorize() async {
    if (!configured) throw StateError('请先填写谷歌 OAuth 客户端 ID');
    final client = await clientViaUserConsent(_clientId, _scopes, (url) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    });
    _attach(client);
    String hint = '已授权';
    try {
      final about = await drive.DriveApi(client)
          .about
          .get($fields: 'user(emailAddress,displayName)');
      hint = about.user?.emailAddress ?? about.user?.displayName ?? hint;
    } catch (_) {}
    store.updateSettings((s) => s.gdriveAccountHint = hint);
    return hint;
  }

  void signOut() {
    _credSub?.cancel();
    _client?.close();
    _client = null;
    _folderId = null;
    store.updateSettings((s) {
      s.gdriveCredentials = '';
      s.gdriveAccountHint = '';
    });
  }

  Future<drive.DriveApi> _api() async {
    if (_client == null) {
      if (!authorized) throw StateError('尚未授权谷歌云盘');
      final creds = AccessCredentials.fromJson(
          jsonDecode(store.settings.gdriveCredentials) as Map<String, dynamic>);
      final client = autoRefreshingClient(_clientId, creds, http.Client());
      _attach(client);
    }
    return drive.DriveApi(_client!);
  }

  Future<String> _folder(drive.DriveApi api) async {
    if (_folderId != null) return _folderId!;
    final res = await api.files.list(
      q: "name = '$folderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id,name)',
    );
    final found = res.files ?? [];
    if (found.isNotEmpty) return _folderId = found.first.id!;
    final created = await api.files.create(
      drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder',
      $fields: 'id',
    );
    return _folderId = created.id!;
  }

  Future<GDriveBackupFile> upload(String content, String fileName) async {
    final api = await _api();
    final folder = await _folder(api);
    final bytes = utf8.encode(content);
    final f = await api.files.create(
      drive.File()
        ..name = fileName
        ..parents = [folder]
        ..mimeType = 'application/json',
      uploadMedia: drive.Media(Stream.value(bytes), bytes.length,
          contentType: 'application/json'),
      $fields: 'id,name,modifiedTime,size',
    );
    return GDriveBackupFile(
      f.id!,
      f.name ?? fileName,
      f.modifiedTime ?? DateTime.now(),
      int.tryParse(f.size ?? '') ?? bytes.length,
    );
  }

  Future<List<GDriveBackupFile>> list() async {
    final api = await _api();
    final folder = await _folder(api);
    final res = await api.files.list(
      q: "'$folder' in parents and trashed = false",
      spaces: 'drive',
      orderBy: 'modifiedTime desc',
      pageSize: 100,
      $fields: 'files(id,name,modifiedTime,size)',
    );
    return (res.files ?? [])
        .map((f) => GDriveBackupFile(
              f.id!,
              f.name ?? '',
              f.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0),
              int.tryParse(f.size ?? '') ?? 0,
            ))
        .toList();
  }

  Future<String> download(String fileId) async {
    final api = await _api();
    final media = await api.files.get(fileId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
    final chunks = <int>[];
    await for (final c in media.stream) {
      chunks.addAll(c);
    }
    return utf8.decode(chunks);
  }

  Future<void> delete(String fileId) async {
    final api = await _api();
    await api.files.delete(fileId);
  }

  /// 只保留最近 [keep] 份备份。
  Future<void> prune(int keep) async {
    if (keep <= 0) return;
    final files = await list();
    for (final f in files.skip(keep)) {
      try {
        await delete(f.id);
      } catch (_) {}
    }
  }
}
