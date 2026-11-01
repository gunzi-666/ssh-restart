import 'dart:math';

import 'package:xterm/xterm.dart';

/// 开启 reflow 的终端。xterm 重排时上方行合并/拆分会改变行数，但光标仍停在原屏幕行，
/// 后续输出会写错位置；这里用随内容迁移的锚点记录光标，重排后放回正确位置。
class ReflowTerminal extends Terminal {
  ReflowTerminal({super.maxLines}) : super(reflowEnabled: true);

  @override
  void resize(int newWidth, int newHeight, [int? pixelWidth, int? pixelHeight]) {
    final buf = mainBuffer;
    final anchor =
        max(newWidth, 1) != viewWidth ? buf.createAnchorFromCursor() : null;
    super.resize(newWidth, newHeight, pixelWidth, pixelHeight);
    if (anchor == null) return;
    if (anchor.attached) {
      buf.setCursorX(anchor.x.clamp(0, viewWidth - 1));
      buf.setCursorY((anchor.y - buf.scrollBack).clamp(0, viewHeight - 1));
    }
    anchor.dispose();
  }
}
