import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class DiskInfo {
  final String filesystem;
  final String mount;
  final int totalKb;
  final int usedKb;
  final int availKb;
  DiskInfo(this.filesystem, this.mount, this.totalKb, this.usedKb, this.availKb);
  double get percent => totalKb == 0 ? 0 : usedKb / totalKb;
}

class ProcessInfo {
  final int pid;
  final String user;
  final double cpu;
  final double mem;
  final int rssKb;
  final String command;
  ProcessInfo(this.pid, this.user, this.cpu, this.mem, this.rssKb, this.command);
}

class NetIface {
  final String name;
  final int rx;
  final int tx;
  NetIface(this.name, this.rx, this.tx);
}

/// 周期性地在远程主机上执行一段脚本，解析 /proc 数据得到 CPU、内存、网速、磁盘和进程信息。
class ServerMonitor extends ChangeNotifier {
  ServerMonitor(this.client);

  final SSHClient client;
  Timer? _timer;
  bool _running = false;
  bool _busy = false;
  bool supported = true;
  String? error;

  String hostname = '';
  String os = '';
  String kernel = '';
  String cpuModel = '';
  int cpuCores = 0;

  double uptimeSeconds = 0;
  List<double> load = [0, 0, 0];
  double cpuPercent = 0;
  int memTotalKb = 0;
  int memUsedKb = 0;
  int memCacheKb = 0;
  int swapTotalKb = 0;
  int swapUsedKb = 0;

  List<String> interfaces = [];
  String selectedIface = '';
  double rxRate = 0;
  double txRate = 0;
  final List<double> rxHistory = [];
  final List<double> txHistory = [];

  int? pingMs;
  final List<int?> pingHistory = [];

  List<DiskInfo> disks = [];
  List<ProcessInfo> processes = [];

  List<int>? _lastCpu;
  Map<String, NetIface> _lastNet = {};
  DateTime? _lastNetTime;
  static const historyLength = 60;

  static const _sep = '@@SSHR@@';

  static const _staticScript = 'export LC_ALL=C; hostname 2>/dev/null; echo $_sep; '
      '(. /etc/os-release 2>/dev/null && echo "\$PRETTY_NAME") || uname -s; echo $_sep; '
      'uname -srm 2>/dev/null; echo $_sep; '
      "grep -m1 -E 'model name|Hardware|Processor' /proc/cpuinfo 2>/dev/null | cut -d: -f2; echo $_sep; "
      "nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo";

  static const _script = 'export LC_ALL=C; cat /proc/uptime; echo $_sep; '
      'cat /proc/loadavg; echo $_sep; '
      'head -n1 /proc/stat; echo $_sep; '
      "grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo; echo $_sep; "
      'cat /proc/net/dev; echo $_sep; '
      'df -kP 2>/dev/null; echo $_sep; '
      'ps -eo pid=,user=,pcpu=,pmem=,rss=,comm= 2>/dev/null | head -n 400';

  void start(Duration interval) {
    if (_running) {
      _timer?.cancel();
    }
    _running = true;
    _loadStatic();
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  Future<String> _exec(String cmd) async {
    final out = await client.run(cmd, stderr: false);
    return utf8.decode(out, allowMalformed: true);
  }

  Future<void> _loadStatic() async {
    try {
      final parts = (await _exec(_staticScript)).split(_sep);
      String at(int i) => i < parts.length ? parts[i].trim() : '';
      hostname = at(0);
      os = at(1);
      kernel = at(2);
      cpuModel = at(3);
      cpuCores = int.tryParse(at(4)) ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (_busy || client.isClosed) return;
    _busy = true;
    try {
      final sw = Stopwatch()..start();
      await client.ping().timeout(const Duration(seconds: 5));
      pingMs = sw.elapsedMilliseconds;
    } catch (_) {
      pingMs = null;
    }
    _push(pingHistory, pingMs);

    try {
      final text = await _exec(_script).timeout(const Duration(seconds: 15));
      _parse(text.split(_sep));
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      _busy = false;
      if (_running) notifyListeners();
    }
  }

  void _push<T>(List<T> list, T v) {
    list.add(v);
    if (list.length > historyLength) list.removeAt(0);
  }

  void _parse(List<String> parts) {
    String at(int i) => i < parts.length ? parts[i].trim() : '';
    if (at(0).isEmpty && at(2).isEmpty) {
      supported = false;
      return;
    }
    supported = true;

    uptimeSeconds = double.tryParse(at(0).split(RegExp(r'\s+')).first) ?? 0;

    final l = at(1).split(RegExp(r'\s+'));
    if (l.length >= 3) {
      load = [
        double.tryParse(l[0]) ?? 0,
        double.tryParse(l[1]) ?? 0,
        double.tryParse(l[2]) ?? 0,
      ];
    }

    final cpu = at(2)
        .split(RegExp(r'\s+'))
        .skip(1)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    if (cpu.length >= 4) {
      if (_lastCpu != null && _lastCpu!.length == cpu.length) {
        int sum(List<int> v) => v.fold(0, (a, b) => a + b);
        final idle = (cpu[3] + (cpu.length > 4 ? cpu[4] : 0)) -
            (_lastCpu![3] + (_lastCpu!.length > 4 ? _lastCpu![4] : 0));
        final total = sum(cpu) - sum(_lastCpu!);
        if (total > 0) cpuPercent = ((total - idle) / total).clamp(0.0, 1.0);
      }
      _lastCpu = cpu;
    }

    final mem = <String, int>{};
    for (final line in at(3).split('\n')) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line.trim());
      if (m != null) mem[m.group(1)!] = int.parse(m.group(2)!);
    }
    memTotalKb = mem['MemTotal'] ?? 0;
    final cache =
        (mem['Buffers'] ?? 0) + (mem['Cached'] ?? 0) + (mem['SReclaimable'] ?? 0);
    memCacheKb = cache;
    final avail = mem['MemAvailable'] ?? ((mem['MemFree'] ?? 0) + cache);
    memUsedKb = (memTotalKb - avail).clamp(0, memTotalKb);
    swapTotalKb = mem['SwapTotal'] ?? 0;
    swapUsedKb = (swapTotalKb - (mem['SwapFree'] ?? 0)).clamp(0, swapTotalKb);

    final now = DateTime.now();
    final net = <String, NetIface>{};
    for (final line in at(4).split('\n')) {
      if (!line.contains(':')) continue;
      final idx = line.indexOf(':');
      final name = line.substring(0, idx).trim();
      final f = line.substring(idx + 1).trim().split(RegExp(r'\s+'));
      if (f.length < 9) continue;
      net[name] = NetIface(name, int.tryParse(f[0]) ?? 0, int.tryParse(f[8]) ?? 0);
    }
    interfaces = net.keys.where((n) => n != 'lo').toList();
    if (_lastNetTime != null) {
      final dt = now.difference(_lastNetTime!).inMilliseconds / 1000.0;
      if (dt > 0) {
        int rx = 0, tx = 0;
        for (final e in net.values) {
          if (e.name == 'lo') continue;
          if (selectedIface.isNotEmpty && e.name != selectedIface) continue;
          final last = _lastNet[e.name];
          if (last == null) continue;
          rx += (e.rx - last.rx).clamp(0, 1 << 52);
          tx += (e.tx - last.tx).clamp(0, 1 << 52);
        }
        rxRate = rx / dt;
        txRate = tx / dt;
        _push(rxHistory, rxRate);
        _push(txHistory, txRate);
      }
    }
    _lastNet = net;
    _lastNetTime = now;

    final ds = <DiskInfo>[];
    final skip = RegExp(r'^(tmpfs|devtmpfs|overlay|udev|none|shm|run|cgroup)');
    for (final line in at(5).split('\n').skip(1)) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 6) continue;
      if (skip.hasMatch(f[0])) continue;
      final total = int.tryParse(f[1]) ?? 0;
      if (total == 0) continue;
      ds.add(DiskInfo(f[0], f.sublist(5).join(' '), total,
          int.tryParse(f[2]) ?? 0, int.tryParse(f[3]) ?? 0));
    }
    disks = ds;

    final ps = <ProcessInfo>[];
    for (final line in at(6).split('\n')) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 6) continue;
      final pid = int.tryParse(f[0]);
      if (pid == null) continue;
      ps.add(ProcessInfo(
        pid,
        f[1],
        double.tryParse(f[2]) ?? 0,
        double.tryParse(f[3]) ?? 0,
        int.tryParse(f[4]) ?? 0,
        f.sublist(5).join(' '),
      ));
    }
    processes = ps;
  }

  void selectIface(String name) {
    selectedIface = name;
    rxHistory.clear();
    txHistory.clear();
    notifyListeners();
  }

  Future<String> killProcess(int pid, {String signal = 'TERM'}) async {
    final r = await client.runWithResult('kill -$signal $pid');
    final msg = utf8.decode(r.output, allowMalformed: true).trim();
    if (r.exitCode != 0) {
      throw StateError(msg.isEmpty ? '结束进程失败' : msg);
    }
    _tick();
    return msg;
  }
}
