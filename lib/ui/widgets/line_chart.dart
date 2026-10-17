import 'dart:math';

import 'package:flutter/material.dart';

class ChartSeries {
  final List<double?> values;
  final Color color;
  final bool fill;
  ChartSeries(this.values, this.color, {this.fill = true});
}

/// 轻量折线图，用于网速和延迟曲线。
class MiniLineChart extends StatelessWidget {
  const MiniLineChart({
    super.key,
    required this.series,
    this.capacity = 60,
    this.height = 70,
    this.minMax = 1,
    this.labelBuilder,
  });

  final List<ChartSeries> series;
  final int capacity;
  final double height;
  final double minMax;
  final String Function(double max)? labelBuilder;

  @override
  Widget build(BuildContext context) {
    double maxV = minMax;
    for (final s in series) {
      for (final v in s.values) {
        if (v != null && v > maxV) maxV = v;
      }
    }
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ChartPainter(
                series,
                capacity,
                maxV * 1.1,
                theme.dividerColor.withValues(alpha: 0.4),
              ),
            ),
          ),
          if (labelBuilder != null)
            Positioned(
              left: 2,
              top: 0,
              child: Text(labelBuilder!(maxV),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.hintColor, fontSize: 10)),
            ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.series, this.capacity, this.maxV, this.gridColor);
  final List<ChartSeries> series;
  final int capacity;
  final double maxV;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final step = size.width / max(1, capacity - 1);
    for (final s in series) {
      final vals = s.values;
      if (vals.isEmpty) continue;
      final start = capacity - vals.length;
      final path = Path();
      final fillPath = Path();
      var started = false;
      double lastX = 0;
      for (var i = 0; i < vals.length; i++) {
        final v = vals[i];
        if (v == null) continue;
        final x = (start + i) * step;
        final y = size.height - (v / maxV) * size.height;
        if (!started) {
          path.moveTo(x, y);
          fillPath.moveTo(x, size.height);
          fillPath.lineTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
          fillPath.lineTo(x, y);
        }
        lastX = x;
      }
      if (!started) continue;
      if (s.fill) {
        fillPath
          ..lineTo(lastX, size.height)
          ..close();
        canvas.drawPath(
            fillPath, Paint()..color = s.color.withValues(alpha: 0.18));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
