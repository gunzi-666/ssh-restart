import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_restart/services/ssh/server_monitor.dart';

void main() {
  test('CPU 核数显示：物理机超线程区分核与线程，虚拟机按 vCPU', () {
    expect(ServerMonitor.coresLabel(8, 4, false), '4核8线程');
    expect(ServerMonitor.coresLabel(8, 8, false), '8核');
    expect(ServerMonitor.coresLabel(8, 4, true), '8核');
    expect(ServerMonitor.coresLabel(4, 0, false), '4核');
    expect(ServerMonitor.coresLabel(2, 16, false), '2核');
    expect(ServerMonitor.coresLabel(0, 0, false), '');
  });
}
