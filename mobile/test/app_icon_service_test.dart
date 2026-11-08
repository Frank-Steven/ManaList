import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_icon_service.dart';

/// 应用图标服务（ux-fixes-2026-11 §1.2）：
/// 同步快路径 / 失败分类（null 只在包不存在时记忆）/ 磁盘写失败不影响返回 /
/// 批量预热。全部经注入的 fetcher 测试，不走真实平台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = AppIconService.instance;
  final png = Uint8List.fromList(const [1, 2, 3, 4]);

  setUp(svc.debugReset);

  test('磁盘命中：不走通道，结果入内存表', () async {
    var channelCalls = 0;
    svc.diskReaderOverride = (_) async => png;
    svc.channelFetcherOverride = (_) async {
      channelCalls++;
      return null;
    };
    svc.diskWriterOverride = (_, __) async {};

    expect(await svc.iconFor('a.b'), png);
    expect(channelCalls, 0);
    expect(svc.cached('a.b'), png);
  });

  test('通道成功 + 磁盘写失败：仍返回字节并入内存', () async {
    svc.diskReaderOverride = (_) async => null;
    svc.channelFetcherOverride = (_) async => png;
    svc.diskWriterOverride = (_, __) async => throw StateError('disk full');

    expect(await svc.iconFor('a.b'), png);
    expect(svc.cached('a.b'), png);
  });

  test('包不存在：记忆 null，第二次不再取通道', () async {
    var calls = 0;
    svc.diskReaderOverride = (_) async => null;
    svc.channelFetcherOverride = (pkg) async {
      calls++;
      throw AppIconNotFoundException(pkg);
    };

    expect(await svc.iconFor('gone.app'), isNull);
    expect(await svc.iconFor('gone.app'), isNull);
    expect(calls, 1);
    expect(svc.hasCached('gone.app'), isTrue);
    expect(svc.cached('gone.app'), isNull);
  });

  test('瞬时失败：不记忆，下次访问重试并可成功', () async {
    var calls = 0;
    svc.diskReaderOverride = (_) async => null;
    svc.channelFetcherOverride = (_) async {
      calls++;
      if (calls == 1) throw StateError('transient');
      return png;
    };
    svc.diskWriterOverride = (_, __) async {};

    expect(await svc.iconFor('a.b'), isNull);
    expect(svc.hasCached('a.b'), isFalse);
    expect(await svc.iconFor('a.b'), png);
    expect(calls, 2);
  });

  test('通道返回空字节：按瞬时处理，不记忆', () async {
    svc.diskReaderOverride = (_) async => null;
    svc.channelFetcherOverride = (_) async => Uint8List(0);
    expect(await svc.iconFor('a.b'), isNull);
    expect(svc.hasCached('a.b'), isFalse);
  });

  test('prewarm：磁盘命中不进通道，其余批量取回并写盘', () async {
    final written = <String>[];
    final batchRequests = <List<String>>[];
    svc.diskReaderOverride =
        (pkg) async => pkg == 'disk.hit' ? png : null;
    svc.batchFetcherOverride = (pkgs) async {
      batchRequests.add(List.of(pkgs));
      return {for (final p in pkgs) p: png};
    };
    svc.diskWriterOverride = (pkg, _) async => written.add(pkg);

    await svc.prewarm(['disk.hit', 'a.b', 'c.d']);

    expect(svc.cached('disk.hit'), png);
    expect(svc.cached('a.b'), png);
    expect(svc.cached('c.d'), png);
    expect(batchRequests.single, unorderedEquals(['a.b', 'c.d']));
    expect(written, unorderedEquals(['a.b', 'c.d']));

    // 已全部缓存：再次预热不再发起任何加载
    await svc.prewarm(['disk.hit', 'a.b', 'c.d']);
    expect(batchRequests.length, 1);
  });

  test('prewarm：批量通道不可用时回退逐条加载', () async {
    svc.diskReaderOverride = (_) async => null;
    svc.batchFetcherOverride =
        (_) async => throw StateError('no batch channel');
    svc.channelFetcherOverride = (_) async => png;
    svc.diskWriterOverride = (_, __) async {};

    await svc.prewarm(['x.y', 'z.w']);
    expect(svc.cached('x.y'), png);
    expect(svc.cached('z.w'), png);
  });
}
