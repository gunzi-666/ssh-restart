import 'package:flutter/material.dart';

import '../services/ssh/server_monitor.dart';
import '../state/ssh_tab.dart';
import 'widgets/common.dart';
import 'widgets/line_chart.dart';

/// 左侧状态面板：系统信息、CPU/内存/交换、进程、网速、延迟、磁盘。
class MonitorPanel extends StatelessWidget {
  const MonitorPanel({super.key, required this.tab});
  final SshTab tab;

  @override
  Widget build(BuildContext context) {
    final m = tab.monitor;
    if (m == null) {
      return const Center(child: Text('未连接', style: TextStyle(fontSize: 12)));
    }
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => _content(context, m),
    );
  }

  Widget _kv(BuildContext context, String k, String v, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              k,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _content(BuildContext context, ServerMonitor m) {
    final theme = Theme.of(context);
    if (!m.supported) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '该服务器不是 Linux 系统，或未提供 /proc 信息，无法显示状态监控。',
          style: TextStyle(fontSize: 12),
        ),
      );
    }
    final topProcs = [...m.processes]..sort((a, b) => b.mem.compareTo(a.mem));
    final cs = theme.colorScheme;
    const up = Color(0xFFF5A524);
    const down = Color(0xFF3DD68C);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      children: [
        // 系统信息卡片
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(
                context,
                'IP',
                tab.config.host,
                trailing: InkWell(
                  onTap: () => copyText(context, tab.config.host),
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.copy, size: 14),
                  ),
                ),
              ),
              if (m.hostname.isNotEmpty) _kv(context, '主机', m.hostname),
              if (m.os.isNotEmpty) _kv(context, '系统', m.os),
              if (m.cpuModel.isNotEmpty)
                _kv(
                  context,
                  'CPU',
                  '${m.cpuCores > 0 ? '${m.cpuCores}核 ' : ''}${m.cpuModel}',
                ),
              _kv(context, '运行', formatDuration(m.uptimeSeconds)),
              _kv(
                context,
                '负载',
                m.load.map((e) => e.toStringAsFixed(2)).join(', '),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 占用率卡片
        AppCard(
          child: Column(
            children: [
              UsageBar(
                label: 'CPU',
                value: m.cpuPercent,
                text: '${(m.cpuPercent * 100).toStringAsFixed(0)}%',
              ),
              UsageBar(
                label: '内存',
                value: m.memTotalKb == 0 ? 0 : m.memUsedKb / m.memTotalKb,
                text: m.memTotalKb == 0
                    ? '-'
                    : '${(m.memUsedKb * 100 / m.memTotalKb).toStringAsFixed(0)}%  '
                          '${formatBytes(m.memUsedKb * 1024)}/${formatBytes(m.memTotalKb * 1024)}',
              ),
              UsageBar(
                label: '交换',
                value: m.swapTotalKb == 0 ? 0 : m.swapUsedKb / m.swapTotalKb,
                text: m.swapTotalKb == 0
                    ? '未启用'
                    : '${(m.swapUsedKb * 100 / m.swapTotalKb).toStringAsFixed(0)}%  '
                          '${formatBytes(m.swapUsedKb * 1024)}/${formatBytes(m.swapTotalKb * 1024)}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 网络曲线卡片（含上传/下载速率）
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('网络', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 8),
                  const Spacer(),
                  if (m.interfaces.isNotEmpty)
                    Flexible(
                      flex: 100,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 118),
                        child: AppSelect<String>(
                          dense: true,
                          width: double.infinity,
                          value: m.interfaces.contains(m.selectedIface)
                              ? m.selectedIface
                              : '',
                          options: [
                            (value: '', label: '全部网卡'),
                            for (final i in m.interfaces) (value: i, label: i),
                          ],
                          onChanged: m.selectIface,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.arrow_upward, size: 13, color: up),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      formatSpeed(m.txRate < 0 ? 0 : m.txRate),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: up,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_downward, size: 13, color: down),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      formatSpeed(m.rxRate < 0 ? 0 : m.rxRate),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: down,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              MiniLineChart(
                series: [
                  ChartSeries(m.txHistory, up),
                  ChartSeries(m.rxHistory, down),
                ],
                minMax: 1024,
                labelBuilder: (v) => formatSpeed(v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 延迟卡片
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('延迟', style: theme.textTheme.labelMedium),
                  const Spacer(),
                  Text(
                    m.pingMs == null ? '超时' : '${m.pingMs} ms',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: m.pingMs == null
                          ? const Color(0xFFE5484D)
                          : m.pingMs! > 200
                          ? up
                          : down,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              MiniLineChart(
                series: [
                  ChartSeries(
                    m.pingHistory.map((e) => e?.toDouble()).toList(),
                    cs.primary,
                    fill: false,
                  ),
                ],
                height: 50,
                minMax: 50,
                labelBuilder: (v) => '${v.toStringAsFixed(0)}ms',
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 进程卡片
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('进程', style: theme.textTheme.labelMedium),
                  ),
                  InkWell(
                    onTap: () => showProcessManager(context, m),
                    borderRadius: BorderRadius.circular(6),
                    child: Text(
                      '全部进程',
                      style: TextStyle(fontSize: 12, color: cs.primary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Table(
                columnWidths: const {
                  0: FixedColumnWidth(52),
                  1: FixedColumnWidth(40),
                  2: FlexColumnWidth(),
                },
                children: [
                  TableRow(
                    children: [
                      for (final h in ['内存', 'CPU', '命令'])
                        Text(
                          h,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.hintColor,
                          ),
                        ),
                    ],
                  ),
                  for (final p in topProcs.take(6))
                    TableRow(
                      children: [
                        Text(
                          formatBytes(p.rssKb * 1024),
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          p.cpu.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 11),
                        ),
                        Text(
                          p.command,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 磁盘卡片
        if (m.disks.isNotEmpty)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('磁盘', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                for (final d in m.disks)
                  Tooltip(
                    message:
                        '${d.filesystem}\n已用 ${formatBytes(d.usedKb * 1024)}，'
                        '可用 ${formatBytes(d.availKb * 1024)}',
                    child: UsageBar(
                      label: d.mount.length > 6
                          ? '…${d.mount.substring(d.mount.length - 5)}'
                          : d.mount,
                      value: d.percent,
                      text:
                          '${formatBytes(d.availKb * 1024)}/${formatBytes(d.totalKb * 1024)}',
                    ),
                  ),
              ],
            ),
          ),
        if (m.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '监控出错：${m.error}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFE5484D)),
            ),
          ),
      ],
    );
  }
}

Future<void> showProcessManager(BuildContext context, ServerMonitor m) {
  return showDialog(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: (size.width - 48).clamp(360.0, 880.0),
          height: (size.height - 48).clamp(320.0, 640.0),
          child: _ProcessManager(monitor: m),
        ),
      );
    },
  );
}

class _ProcessManager extends StatefulWidget {
  const _ProcessManager({required this.monitor});
  final ServerMonitor monitor;

  @override
  State<_ProcessManager> createState() => _ProcessManagerState();
}

class _ProcessManagerState extends State<_ProcessManager> {
  int _sortCol = 3;
  bool _asc = false;
  String _filter = '';

  Future<void> _kill(ProcessInfo p, String sig) async {
    final ok = await confirm(
      context,
      title: '结束进程',
      message: '确定向进程 ${p.pid} (${p.command}) 发送 SIG$sig 信号吗？',
      danger: true,
    );
    if (!ok) return;
    try {
      await widget.monitor.killProcess(p.pid, signal: sig);
      if (mounted) showToast(context, '已发送信号');
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  static const _wPid = 72.0;
  static const _wUser = 96.0;
  static const _wCpu = 64.0;
  static const _wMem = 92.0;
  static const _wAct = 112.0;
  static const _mono = TextStyle(
    fontSize: 12.5,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  TextStyle _headStyle(ColorScheme cs, bool active) => TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: active ? cs.primary : cs.onSurfaceVariant,
      );

  Widget _head(String label, int col, {double? width, bool right = false}) {
    final cs = Theme.of(context).colorScheme;
    final active = _sortCol == col;
    final text = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (active && right)
          Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13, color: cs.primary),
        Text(label, style: _headStyle(cs, active)),
        if (active && !right)
          Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13, color: cs.primary),
      ],
    );
    final cell = InkWell(
      onTap: () => setState(() {
        if (_sortCol == col) {
          _asc = !_asc;
        } else {
          _sortCol = col;
          _asc = col == 1 || col == 4;
        }
      }),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: text,
      ),
    );
    return width == null ? cell : SizedBox(width: width, child: cell);
  }

  Widget _row(ProcessInfo p, int i, ColorScheme cs) {
    Widget btn(String label, String sig, Color color) => SizedBox(
          height: 26,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12.5),
            ),
            onPressed: () => _kill(p, sig),
            child: Text(label),
          ),
        );
    return Material(
      color: i.isOdd
          ? cs.surfaceContainerHighest.withValues(alpha: 0.18)
          : Colors.transparent,
      child: InkWell(
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SizedBox(
                  width: _wPid,
                  child: Text('${p.pid}', textAlign: TextAlign.right, style: _mono)),
              SizedBox(
                width: _wUser,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(p.user,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              SizedBox(
                  width: _wCpu,
                  child: Text(p.cpu.toStringAsFixed(1),
                      textAlign: TextAlign.right,
                      style: _mono.copyWith(
                          color: p.cpu >= 50 ? cs.error : null))),
              SizedBox(
                  width: _wMem,
                  child: Text(formatBytes(p.rssKb * 1024),
                      textAlign: TextAlign.right, style: _mono)),
              const SizedBox(width: 16),
              Expanded(
                child: Tooltip(
                  message: p.command,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(p.command,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              SizedBox(
                width: _wAct,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    btn('结束', 'TERM', cs.primary),
                    btn('强制', 'KILL', cs.error),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.monitor,
      builder: (context, _) {
        var list = widget.monitor.processes
            .where(
              (p) =>
                  _filter.isEmpty ||
                  p.command.toLowerCase().contains(_filter) ||
                  p.user.toLowerCase().contains(_filter) ||
                  '${p.pid}' == _filter,
            )
            .toList();
        int cmp(ProcessInfo a, ProcessInfo b) => switch (_sortCol) {
          0 => a.pid.compareTo(b.pid),
          1 => a.user.compareTo(b.user),
          2 => a.cpu.compareTo(b.cpu),
          3 => a.rssKb.compareTo(b.rssKb),
          _ => a.command.compareTo(b.command),
        };
        list.sort((a, b) => _asc ? cmp(a, b) : cmp(b, a));
        final cs = Theme.of(context).colorScheme;
        final shown = list.take(300).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
              child: Row(
                children: [
                  Text(
                    '进程管理',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 6),
                  Text('${list.length}',
                      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: '按命令、用户或 PID 过滤',
                        ),
                        onChanged: (v) =>
                            setState(() => _filter = v.trim().toLowerCase()),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                border: Border.symmetric(
                    horizontal: BorderSide(color: cs.outlineVariant)),
              ),
              child: Row(
                children: [
                  _head('PID', 0, width: _wPid, right: true),
                  SizedBox(
                    width: _wUser,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: _head('用户', 1),
                    ),
                  ),
                  _head('CPU%', 2, width: _wCpu, right: true),
                  _head('内存', 3, width: _wMem, right: true),
                  const SizedBox(width: 16),
                  Expanded(child: _head('命令', 4)),
                  SizedBox(
                    width: _wAct,
                    child: Text('操作',
                        textAlign: TextAlign.center,
                        style: _headStyle(cs, false)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        widget.monitor.processes.isEmpty ? '正在获取进程列表…' : '没有匹配的进程',
                        style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemExtent: 34,
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _row(shown[i], i, cs),
                    ),
            ),
            if (list.length > shown.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('仅显示前 ${shown.length} 个进程，可输入关键字过滤',
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
              ),
          ],
        );
      },
    );
  }
}
