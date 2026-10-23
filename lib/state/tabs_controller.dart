import 'package:flutter/foundation.dart';

import '../models/session_config.dart';
import '../services/app_store.dart';
import 'app_tab.dart';
import 'ssh_tab.dart';
import 'vnc_tab.dart';

class TabsController extends ChangeNotifier {
  TabsController(this.store);

  final AppStore store;
  final List<AppTab> tabs = [];
  int activeIndex = -1;

  AppTab? get active =>
      activeIndex >= 0 && activeIndex < tabs.length ? tabs[activeIndex] : null;

  List<SshTab> get sshTabs => tabs.whereType<SshTab>().toList();

  AppTab open(SessionConfig config) {
    final cfg = config.copy();
    final AppTab tab =
        cfg.type == SessionType.vnc ? VncTab(cfg, store) : SshTab(cfg, store);
    tabs.add(tab);
    activeIndex = tabs.length - 1;
    notifyListeners();
    tab.connect();
    return tab;
  }

  /// 在后台建立 SSH 连接但暂不加入标签栏，连接成功后由调用方 [attach]。
  SshTab connectInBackground(SessionConfig config) {
    final tab = SshTab(config.copy(), store)..progressViewer = true;
    tab.connect();
    return tab;
  }

  void attach(AppTab tab) {
    if (!tabs.contains(tab)) tabs.add(tab);
    activeIndex = tabs.indexOf(tab);
    notifyListeners();
  }

  /// 复制标签：用同一会话配置再开一个新连接。
  AppTab duplicate(AppTab tab) => open(tab.config);

  void activate(int index) {
    if (index < 0 || index >= tabs.length) return;
    activeIndex = index;
    notifyListeners();
  }

  Future<void> close(AppTab tab) async {
    final i = tabs.indexOf(tab);
    if (i < 0) return;
    tabs.removeAt(i);
    if (activeIndex >= tabs.length) activeIndex = tabs.length - 1;
    if (i < activeIndex) activeIndex--;
    notifyListeners();
    await tab.close();
  }

  Future<void> closeOthers(AppTab keep) async {
    for (final t in tabs.where((t) => t != keep).toList()) {
      await close(t);
    }
  }

  Future<void> closeAll() async {
    for (final t in tabs.toList()) {
      await close(t);
    }
  }

  void move(int from, int to) {
    if (from == to) return;
    final active = this.active;
    final t = tabs.removeAt(from);
    tabs.insert(to > from ? to - 1 : to, t);
    activeIndex = active == null ? -1 : tabs.indexOf(active);
    notifyListeners();
  }

  /// 把同一条命令发送到所有已连接的 SSH 标签。
  void broadcast(String text) {
    for (final t in sshTabs) {
      t.sendText(text);
    }
  }
}
