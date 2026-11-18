import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';

void main() {
  test('去除重复服务器：保留优先项、合并收藏、改写跳板机引用', () {
    final store = AppStore();
    final a1 = SessionConfig(name: '跳板', host: '10.0.0.1', updatedAt: 1);
    final a2 = SessionConfig(name: '跳板', host: '10.0.0.1 ', favorite: true, updatedAt: 2);
    final a3 = SessionConfig(name: '跳板', host: '10.0.0.1', lastConnectedAt: 9, updatedAt: 3);
    final other = SessionConfig(name: '跳板', host: '10.0.0.1', port: 2222);
    final b = SessionConfig(name: '内网', host: '192.168.1.5', jumpSessionId: a3.id);
    for (final s in [a1, a2, a3, other, b]) {
      store.upsertSession(s);
    }

    final groups = store.findDuplicateSessions();
    expect(groups.length, 1);
    expect(groups.single.first.id, a3.id);

    final removed = store.removeDuplicateSessions(groups);
    expect(removed, 2);
    expect(store.sessions.map((s) => s.id).toSet(), {a3.id, other.id, b.id});
    expect(store.sessionById(a3.id)!.favorite, isTrue);
    expect(store.findDuplicateSessions(), isEmpty);
  });

  test('被用作跳板机的服务器优先保留，其余引用改指向它', () {
    final store = AppStore();
    final j1 = SessionConfig(name: 'j', host: '1.1.1.1', lastConnectedAt: 100);
    final j2 = SessionConfig(name: 'j', host: '1.1.1.1');
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

  test('同一地址但名称、密码、备注或转发规则不同的服务器不算重复', () {
    final store = AppStore();
    SessionConfig base() =>
        SessionConfig(name: 'web', host: '3.3.3.3', password: 'p1');
    final same1 = base()..groupId = 'g1';
    final same2 = base()
      ..groupId = 'g2'
      ..favorite = true;
    final variants = [
      base()..name = 'web-2',
      base()..password = 'p2',
      base()..description = '备用账号',
      base()..forwards = [PortForward(bindPort: 8080, destPort: 80)],
    ];
    for (final s in [same1, same2, ...variants]) {
      store.upsertSession(s);
    }
    final groups = store.findDuplicateSessions();
    expect(groups.length, 1);
    expect(groups.single.map((s) => s.id).toSet(), {same1.id, same2.id});
  });
}
