import 'package:flutter/material.dart';

/// 启动页背景色 —— **跟随深浅模式**（2026-10-28 用户拍板，取代 B07/Q13② 的统一品牌蓝）。
///
/// 两档与 `android res/values/colors.xml`、`values-night/colors.xml` 的 `splash_bg`
/// 一一对应，改一处就要同步另一处。已知边界：原生阶段跟系统夜间模式、Flutter 阶段跟
/// App 主题设置，「系统浅 + App 深」的混合档在交接瞬间会有一次深浅跳变，属接受范围。
const Color splashBackgroundLight = Color(0xFFFAFAFA);
const Color splashBackgroundDark = Color(0xFF121212);

/// 按当前主题亮度取启动页背景色。
Color splashBackgroundFor(Brightness brightness) => brightness == Brightness.dark
    ? splashBackgroundDark
    : splashBackgroundLight;

/// 图标边长（dp）。1080px 屏 / 2.75 密度 ≈ 320px，屏宽 29.6%（设计稿口径）。
/// 与原生 `res/drawable/splash_icon_centered.xml` 的 116dp 严格一致。
const double splashIconSize = 116;

/// 图标中心相对屏高的位置 —— 50%（2026-11-01：原生启动窗直显图标，
/// 系统启动窗只支持垂直居中，Flutter 接力必须同位，原 46.5% 设计稿口径
/// 随之统一到几何中心，否则交接瞬间图标会向上跳 ~3.5% 屏高）。
const double splashIconCenterRatio = 0.5;

/// 图标底 → 名称顶的距离（dp）。设计稿 96px @2.75。
const double splashIconToNameGap = 35;

/// 圆角半径占图标边长的比例（设计稿 rx 56 / 256 ≈ 21.875%）。
const double splashIconRadiusRatio = 0.21875;

/// 名称字号（sp）。设计稿 56px @2.75 ≈ 21sp。
const double splashNameFontSize = 21;

/// F15（2026-10-22 用户）启动动画，2026-11-01 起**原生直显图标**（取代 Q13-A）：
/// 用户要求「一点开应用就有开屏」——Flutter 引擎就绪前的几百毫秒由系统启动窗
/// 直接画出底色 + 居中 116dp 图标（`res/drawable/launch_background.xml` 与
/// `windowSplashScreenAnimatedIcon`，版式与本页严格一致），Flutter 首帧无缝接力。
/// 代价：图标不再有 0 → 1 淡入（原生阶段已经全显，再淡入会闪）；
/// 保留的动画 = 名称延后淡入 + 整体退场淡出。
///
/// 设计（2026-10-28 起背景跟随深浅模式）：
/// 1. 图标全程不透明，位置/尺寸与原生启动窗逐像素一致（中心 = 屏高 50%）；
/// 2. 名称延后 150ms 淡入（500ms），避免两块同时跳到脸上（2026-10-28 用户：标语小字移除）；
/// 3. 底层先在**第一帧**画启动页，下一帧才构建 [child]（主界面），这样数据库/页面初始化的
///    重活发生在启动页盖着的时候，而不是让用户盯着白屏；
/// 4. 启动完成（[bootstrap] 完成且不短于 [minimumDuration]）后启动页整体淡出（300ms）。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.bootstrap,
    required this.child,
    this.minimumDuration = const Duration(milliseconds: 900),
  });

  /// 冷启动的重活（提醒初始化、采集轮询等）；完成得再快也不短于 [minimumDuration]。
  final Future<void> bootstrap;

  /// 启动页退场后显示的内容（HomeShell）。
  final Widget child;

  /// 启动页至少停留多久 —— 太快会像闪一下，比加载本身更让人不安。
  final Duration minimumDuration;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> with TickerProviderStateMixin {
  static const Duration _textFade = Duration(milliseconds: 500);
  static const Duration _exitFade = Duration(milliseconds: 300);

  late final AnimationController _text = AnimationController(
    vsync: this,
    duration: _textFade,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitFade,
  );

  bool _mountChild = false;
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // ① 先让启动页自己画上屏，② 再构建主界面（避免重活拖慢第一帧）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _mountChild = true);
    });
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _text.forward();
    });
    _waitAndExit();
  }

  Future<void> _waitAndExit() async {
    try {
      await Future.wait<void>([
        widget.bootstrap,
        Future<void>.delayed(widget.minimumDuration),
      ]);
    } catch (_) {
      // 初始化失败也要退出启动页（主界面自己会报错/降级），不能卡在启动页
    }
    if (!mounted) return;
    await _exit.forward();
    if (!mounted) return;
    setState(() => _showSplash = false);
  }

  @override
  void dispose() {
    _text.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final splash = LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        // 关键版式：图标中心落在屏高 50%，与原生启动窗逐像素对齐
        final iconTop = height * splashIconCenterRatio - splashIconSize / 2;
        final textFade = CurvedAnimation(parent: _text, curve: Curves.easeOut);
        final brightness = Theme.of(context).colorScheme.brightness;
        return ColoredBox(
          color: splashBackgroundFor(brightness),
          child: Stack(
            children: [
              Positioned(
                top: iconTop,
                left: 0,
                right: 0,
                // 图标不做淡入：原生启动窗阶段已经全显（2026-11-01），
                // 再从 0 淡入等于「图标消失再出现」的交接闪烁
                child: const Center(
                  child: _SplashIcon(key: ValueKey('splash-icon')),
                ),
              ),
              Positioned(
                top: iconTop + splashIconSize + splashIconToNameGap,
                left: 0,
                right: 0,
                child: FadeTransition(
                  opacity: textFade,
                  child: Text(
                    'ManaList',
                    key: const ValueKey('splash-name'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: splashNameFontSize,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      // 2026-10-28：背景跟随深浅模式，文字色随之自适应
                      color: brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black87,
                      // 2026-10-24 用户：开屏文字不要下划线
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // 主界面：第一帧之后再挂，重活在启动页盖着时进行
        if (_mountChild) widget.child,
        if (_showSplash)
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(
              CurvedAnimation(parent: _exit, curve: Curves.easeIn),
            ),
            child: splash,
          ),
      ],
    );
  }
}

/// 启动页图标：**圆角卡片**（不是圆形 —— 早期注释写错，B05 复核指出）。
///
/// 圆角用 [splashIconRadiusRatio]（设计稿 rx 56 / 256），与品牌图自身的圆角一致。
/// 卡片**不加外投影**：会撑大视觉包围盒、与设计稿「320px 卡片」的像素口径不符；
/// 深度感由图标图内自带的柔和阴影提供。
class _SplashIcon extends StatelessWidget {
  const _SplashIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(splashIconSize * splashIconRadiusRatio),
      child: Image.asset(
        'assets/splash/icon.png',
        width: splashIconSize,
        height: splashIconSize,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
