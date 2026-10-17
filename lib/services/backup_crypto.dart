import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class BackupDecryptException implements Exception {
  final String message;
  BackupDecryptException(this.message);
  @override
  String toString() => message;
}

/// 备份文件格式：gzip 压缩后的 JSON，用 PBKDF2-SHA256 从用户密钥派生 256 位密钥，再以 AES-256-GCM 加密。
class BackupCrypto {
  static const format = 'ssh-restart-backup';
  static const version = 1;
  static const _iterations = 150000;

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  static Future<SecretKey> _derive(String key, List<int> salt, int iterations) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return kdf.deriveKeyFromPassword(password: key, nonce: salt);
  }

  static Future<String> encrypt(Map<String, dynamic> payload, String key) async {
    if (key.isEmpty) throw ArgumentError('加密密钥不能为空');
    final plain = GZipCodec().encode(utf8.encode(jsonEncode(payload)));
    final salt = _random(16);
    final secret = await _derive(key, salt, _iterations);
    final algo = AesGcm.with256bits();
    final box = await algo.encrypt(plain, secretKey: secret);
    final envelope = {
      'format': format,
      'version': version,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'kdf': {
        'name': 'pbkdf2-hmac-sha256',
        'iterations': _iterations,
        'salt': base64Encode(salt),
      },
      'cipher': 'aes-256-gcm',
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    };
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  static bool looksLikeBackup(String text) {
    try {
      final j = jsonDecode(text);
      return j is Map && j['format'] == format;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> decrypt(String text, String key) async {
    Map<String, dynamic> env;
    try {
      env = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw BackupDecryptException('文件不是有效的备份文件');
    }
    if (env['format'] != format) {
      throw BackupDecryptException('文件不是本软件的备份文件');
    }
    final kdf = env['kdf'] as Map<String, dynamic>;
    final secret = await _derive(
      key,
      base64Decode(kdf['salt'] as String),
      kdf['iterations'] as int,
    );
    final box = SecretBox(
      base64Decode(env['data'] as String),
      nonce: base64Decode(env['nonce'] as String),
      mac: Mac(base64Decode(env['mac'] as String)),
    );
    List<int> plain;
    try {
      plain = await AesGcm.with256bits().decrypt(box, secretKey: secret);
    } on SecretBoxAuthenticationError {
      throw BackupDecryptException('解密失败：加密密钥不正确或文件已损坏');
    }
    final json = utf8.decode(GZipCodec().decode(plain));
    return jsonDecode(json) as Map<String, dynamic>;
  }
}
