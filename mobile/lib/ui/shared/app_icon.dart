import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/app_icon_service.dart';

/// 来源应用图标：内存命中当帧渲染（[AppIconService.cached] 同步快路径），
/// 未命中异步加载。加载中与确认无图标都显示「应用名首字符占位块」——
/// 不再用空 SizedBox 占位（首屏图标位不再空白，ux-fixes-2026-11 §1.2-2）。
class AppIcon extends StatefulWidget {
  final String packageName;
  final String? appName;
  final double size;

  const AppIcon({
    super.key,
    required this.packageName,
    this.appName,
    this.size = 18,
  });

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    // 同步快路径：内存已缓存则首帧直接渲染，不再走异步
    _bytes = AppIconService.instance.cached(widget.packageName);
    if (_bytes == null) _load();
  }

  @override
  void didUpdateWidget(AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _bytes = AppIconService.instance.cached(widget.packageName);
      if (_bytes == null) _load();
    }
  }

  Future<void> _load() async {
    final bytes = await AppIconService.instance.iconFor(widget.packageName);
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  Widget _placeholder(double size, ColorScheme cs) {
    final name = (widget.appName?.isNotEmpty == true
        ? widget.appName!
        : widget.packageName);
    final label = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: size * 0.55, color: cs.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final bytes = _bytes;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          gaplessPlayback: true,
        ),
      );
    }
    return _placeholder(size, Theme.of(context).colorScheme);
  }
}
