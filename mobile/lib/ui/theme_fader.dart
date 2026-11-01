import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 主题切换的「快照渐变」过渡（2026-10-20，O10 第二方案）。
///
/// 为什么不用 `AnimatedTheme` 的插值过渡：那段动画会让**整棵树逐帧重建**，
/// 真机实测单帧 build 200~960ms（raster 只有 3~8ms），观感是「一顿一顿」而不是渐变。
///
/// 现在的做法（本质是「先拍照片，再换装，最后把照片淡出」）：
/// 1) 切换前抓当前界面的一帧位图（一次 GPU 读回，约 20~60ms）；
/// 2) **立刻**换主题（`themeAnimationDuration: Duration.zero`，无逐帧重建）；
/// 3) 把那张位图盖在最上层，用 260ms 淡出 —— 静止位图的透明度动画几乎全在 GPU 合成，
///    帧率稳定，视觉上就是一次平滑渐变。
///
/// 抓帧失败（如首帧未绘制）时退化为瞬时切换，不会阻断主题切换本身。
class ThemeFader extends StatefulWidget {
  const ThemeFader({super.key, required this.child});

  final Widget child;

  /// 需要抓帧的区域（包住 MaterialApp 的内容区）。
  static final GlobalKey boundaryKey = GlobalKey();

  static _ThemeFaderState? _state;

  /// 切换主题：抓快照 → 立刻 apply() → 快照淡出。
  ///
  /// [apply] 里只做一件事：把新的 ThemeMode 写进 notifier。
  static Future<void> switchTo(VoidCallback apply) async {
    final state = _state;
    if (state == null) {
      apply();
      return;
    }
    await state._snapshotThenApply(apply);
  }

  @override
  State<ThemeFader> createState() => _ThemeFaderState();
}

class _ThemeFaderState extends State<ThemeFader>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  bool _busy = false;

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1, // 1 = 快照完全不透明
  )..addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        final img = _image;
        if (mounted) setState(() => _image = null);
        img?.dispose();
      }
    });

  @override
  void initState() {
    super.initState();
    ThemeFader._state = this;
  }

  @override
  void dispose() {
    _fade.dispose();
    _image?.dispose();
    ThemeFader._state = null;
    super.dispose();
  }

  Future<void> _snapshotThenApply(VoidCallback apply) async {
    if (_busy) {
      apply();
      return;
    }
    _busy = true;
    ui.Image? shot;
    try {
      final ro = ThemeFader.boundaryKey.currentContext?.findRenderObject();
      if (ro is RenderRepaintBoundary) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        shot = await ro.toImage(pixelRatio: dpr.clamp(1.0, 2.0));
      }
    } catch (_) {
      // 抓帧失败不影响切主题
      shot = null;
    }
    apply();
    if (shot == null) {
      _busy = false;
      return;
    }
    if (!mounted) {
      shot.dispose();
      _busy = false;
      return;
    }
    setState(() => _image = shot);
    _fade.value = 1;
    await _fade.animateTo(0, curve: Curves.easeOut);
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: ThemeFader.boundaryKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_image != null)
            IgnorePointer(
              child: FadeTransition(
                opacity: _fade,
                child: RawImage(
                  image: _image,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.none,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
