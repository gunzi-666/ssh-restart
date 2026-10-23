import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/services/updater.dart';

void main() {
  test('版本号比较', () {
    expect(Updater.compareVersions('1.0.8', '1.0.7'), greaterThan(0));
    expect(Updater.compareVersions('1.0.7', '1.0.7'), 0);
    expect(Updater.compareVersions('1.0.7+8', '1.0.7'), 0);
    expect(Updater.compareVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(Updater.compareVersions('1.1', '1.0.9'), greaterThan(0));
    expect(Updater.compareVersions('0.9.9', '1.0.0'), lessThan(0));
  });

  test('解析 GitHub Release', () {
    final r = ReleaseInfo.fromJson({
      'tag_name': 'v1.0.8',
      'body': ' 更新说明 ',
      'html_url': 'https://github.com/gunzi-666/ssh-restart/releases/tag/v1.0.8',
      'published_at': '2026-10-24T00:00:00Z',
      'assets': [
        {
          'name': 'SSH-Restart-Windows.zip',
          'browser_download_url': 'https://example.com/w.zip',
          'size': 1024,
          'digest': 'sha256:ABCDEF',
        },
        {
          'name': 'SSH-Restart-universal.apk',
          'browser_download_url': 'https://example.com/a.apk',
          'size': 2048,
        },
      ],
    });
    expect(r.version, '1.0.8');
    expect(r.notes, '更新说明');
    expect(r.assets.first.sha256, 'abcdef');
    expect(r.assets.last.sha256, isNull);
  });
}
