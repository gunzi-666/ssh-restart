import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';

void main() {
  test('去除重复服务器：保留优先项、合并收藏、改写跳板机引用', () {
    final store = AppStore();
    final a1 = SessionConfig(name: '跳板1', host: '10.0.0.1', updatedAt: 1);
    final a2 = SessionConfig(name: '跳板2', host: '10.0.0.1 ', favorite: true, updatedAt: 2);
    final a3 = SessionConfig(name: '跳板3', host: '10.0.0.1', lastConnectedAt: 9, updatedAt: 3);
    final other = SessionConfig(name: '其他端口', host: '10.0.0.1', port: 2222);
    final b = SessionConfig(name: '内网', host: '192.168.1.5', jumpSessionId: a3.id);
    for (final s in [a1, a2, a3, other, b]) {
      store.upsertSession(s);
    }

    final groups = store.findDuplicateSessions();
    expect(groups.length, 1);
    expect(groups.single.first.id, a3.id);

    final removed = store.removeDuplicateSessions(groups);
    expect(removed, 2);
    expect(store.sessions.map((s) => s.name).toSet(), {'跳板3', '其他端口', '内网'});
    expect(store.sessionById(a3.id)!.favorite, isTrue);
    expect(store.findDuplicateSessions(), isEmpty);
  });

  test('被用作跳板机的服务器优先保留，其余引用改指向它', () {
    final store = AppStore();
    final j1 = SessionConfig(name: 'j1', host: '1.1.1.1', lastConnectedAt: 100);
    final j2 = SessionConfig(name: 'j2', host: '1.1.1.1');
    final t1 = SessionConfig(name: 't1', host: '2.2.2.2', jumpSessionId: j2.id);
    for (final s in [j1, j2, t1]) {
      store.upsertSession(s);
    }
    final groups = store.findDuplicateSessions();
    expect(groups.single.first.id, j2.id);
    store.removeDuplicateSessions(groups);
    expect(store.sessionById(j1.id), isNull);
    expect(store.sessionById(t1.id)!.jumpSessionId, j2.id);
  });
}
