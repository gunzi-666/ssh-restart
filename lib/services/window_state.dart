import 'dart:async';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app_store.dart';

/// 记住桌面端窗口的位置、大小与最大化状态，下次启动时恢复。
class WindowStateKeeper with WindowListener {
  WindowStateKeeper(this.store, {Rect? restoreBounds})
      : _restoreBounds = restoreBounds;

  final AppStore store;
  Timer? _timer;

  /// 以最大化状态启动时，首次还原需要回到上次的位置。
  Rect? _restoreBounds;

  static const minSize = Size(900, 560);

  /// 上次保存的窗口区域；不存在或已不在任何屏幕内（如副屏已拔掉）时返回 null。
  static Future<Rect?> savedBounds(AppStore store) async {
    final b = store.settings.windowBounds;
    if (b.length != 4) return null;
    final rect = Rect.fromLTWH(
      b[0],
      b[1],
      b[2].clamp(minSize.width, 10000).toDouble(),
      b[3].clamp(minSize.height, 10000).toDouble(),
    );
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final pos = d.visiblePosition ?? Offset.zero;
        final size = d.visibleSize ?? d.size;
        final area = pos & size;
        final hit = area.intersect(rect);
        // 标题栏附近要有足够区域落在屏幕内，才能被拖动。
        if (hit.width >= 120 && hit.height >= 60 && rect.top >= area.top - 8) {
          return rect;
        }
      }
      return null;
    } catch (_) {
      return rect;
    }
  }

  void start() {
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    refreshLayout();
  }

  /// 隐藏系统标题栏时，窗口在显示前被移动/缩放（尤其跨越不同缩放比例的屏幕）后，
  /// Flutter 画面可能停留在旧尺寸，直到用户手动拖动窗口。这里把宽度临时 +1 再还原，
  /// 强制重新布局。最大化/全屏时系统会自行调整，不做处理。
  static Future<void> refreshLayout() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen() ||
          await windowManager.isMinimized()) {
        return;
      }
      final b = await windowManager.getBounds();
      await windowManager.setBounds(
        Rect.fromLTWH(b.left, b.top, b.width + 1, b.height),
      );
      await windowManager.setBounds(b);
    } catch (_) {}
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _capture);
  }

  Future<void> _capture() async {
    if (await windowManager.isMinimized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    if (await windowManager.isMaximized()) {
      store.persistSettings((s) => s.windowMaximized = true);
      return;
    }
    final b = await windowManager.getBounds();
    store.persistSettings((s) {
      s.windowMaximized = false;
      s.windowBounds = [b.left, b.top, b.width, b.height];
    });
  }

  @override
  void onWindowResized() => _schedule();

  @override
  void onWindowResize() => _schedule();

  @override
  void onWindowMoved() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  Future<void> onWindowUnmaximize() async {
    final r = _restoreBounds;
    _restoreBounds = null;
    if (r != null) await windowManager.setBounds(r);
    await refreshLayout();
    _schedule();
  }

  @override
  void onWindowRestore() => refreshLayout();

  @override
  Future<void> onWindowClose() async {
    _timer?.cancel();
    try {
      await _capture();
      await store.saveNow();
    } finally {
      await windowManager.destroy();
    }
  }
}
