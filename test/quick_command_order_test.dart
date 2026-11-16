import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/models/session_config.dart';
import 'package:ssh_restart/services/app_store.dart';

void main() {
  List<String> names(AppStore s) => [for (final q in s.quickCommands) q.name];
  String idOf(AppStore s, String name) =>
      s.quickCommands.firstWhere((q) => q.name == name).id;

  test('新命令追加到末尾，按布局写回顺序和分组', () {
    final store = AppStore();
    for (final (n, g) in [('a1', 'A'), ('a2', 'A'), ('b1', 'B')]) {
      store.upsertQuickCommand(QuickCommand(name: n, command: n, group: g));
    }
    expect(names(store), ['a1', 'a2', 'b1']);

    store.applyQuickLayout(['B', 'A'], [
      (idOf(store, 'b1'), 'B'),
      (idOf(store, 'a2'), 'B'),
      (idOf(store, 'a1'), 'A'),
    ]);
    expect(names(store), ['b1', 'a2', 'a1']);
    expect(store.quickCommands[1].group, 'B');
    expect(store.quickCommandGroups, ['B', 'A']);
  });

  test('分组顺序：保存的顺序优先，其余按首次出现', () {
    final store = AppStore();
    for (final (n, g) in [('1', 'X'), ('2', 'Y'), ('3', 'Z')]) {
      store.upsertQuickCommand(QuickCommand(name: n, command: n, group: g));
    }
    expect(store.quickCommandGroups, ['X', 'Y', 'Z']);
    store.reorderQuickGroups(['Z', 'X', '已不存在']);
    expect(store.quickCommandGroups, ['Z', 'X', 'Y']);
  });

  test('重命名和删除分组', () {
    final store = AppStore();
    for (final (n, g) in [('1', 'X'), ('2', 'Y'), ('3', 'X')]) {
      store.upsertQuickCommand(QuickCommand(name: n, command: n, group: g));
    }
    store.reorderQuickGroups(['Y', 'X']);
    store.renameQuickGroup('X', '新名');
    expect(store.quickCommandGroups, ['Y', '新名']);
    expect(store.quickCommands.where((q) => q.group == '新名').length, 2);

    store.deleteQuickGroup('Y');
    expect(names(store), ['1', '3']);
    expect(store.quickCommandGroups, ['新名']);
  });
}
