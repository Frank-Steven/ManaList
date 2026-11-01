import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/app_log.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// E03 回归（2026-10-25）：移动端大部分时间电脑端都不在线，
/// health 探测失败是常态 —— 不该写进设置页「最近错误」（原来每次探测都
/// `AppLog.warn('ai.health')`，把真故障淹了）。
///
/// 但降噪只针对「离线预期」（超时 / socket 连不上）；证书、解析、非预期
/// 网络层异常仍必须留痕，别掩盖真问题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppLog.instance.clear();
    AiClient.secretStore = InMemorySecretStore();
    SharedPreferences.setMockInitialValues({});
    AiClient.instance.closeClient();
  });

  tearDown(() {
    AiClient.instance.closeClient();
    AiClient.clientFactory = () => http.Client();
    AppLog.instance.clear();
  });

  group('isExpectedOfflineError：只认离线预期', () {
    test('超时 / socket 连不上算离线', () {
      expect(isExpectedOfflineError(TimeoutException('2s 探测超时')), isTrue);
      expect(isExpectedOfflineError(const SocketException('Connection refused')), isTrue);
      expect(isExpectedOfflineError(const SocketException('Failed host lookup: pc.local')),
          isTrue);
    });

    test('证书 / 解析 / 非预期网络层异常不算离线', () {
      expect(isExpectedOfflineError(const HandshakeException('证书不匹配')), isFalse);
      expect(isExpectedOfflineError(const FormatException('bad health payload')), isFalse);
      // 裸 ClientException（如连接被提前关闭）：不是 socket 层错误，仍要留痕
      expect(isExpectedOfflineError(http.ClientException('Connection closed')), isFalse);
      expect(isExpectedOfflineError(StateError('boom')), isFalse);
    });
  });

  group('reportHealthProbeError：留痕策略', () {
    test('离线预期 → 不写 AppLog', () {
      reportHealthProbeError(const SocketException('Connection refused'), StackTrace.empty);
      reportHealthProbeError(TimeoutException('2s'), StackTrace.empty);
      expect(AppLog.instance.count, 0, reason: '离线不该进「最近错误」');
    });

    test('非预期 → 仍写 AppLog（scope=ai.health）', () {
      reportHealthProbeError(const HandshakeException('证书不匹配'), StackTrace.empty);
      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.scope, 'ai.health');
      expect(AppLog.instance.latest!.message, contains('证书'));
    });
  });

  group('真实探测路径（fake http client）', () {
    /// 装一个 send 必失败（[error]）的 client，并返回调用计数闭包。
    int Function() installThrowing(Object error) {
      var sends = 0;
      AiClient.clientFactory = () => _ThrowingClient(error, () => sends++);
      return () => sends;
    }

    test('连不上：返回 false，且不进最近错误', () async {
      installThrowing(const SocketException('Connection refused'));

      expect(await AiClient.instance.isDesktopOnline(force: true), isFalse);

      expect(AppLog.instance.count, 0, reason: '离线探测不该产生「最近错误」');
    });

    test('探测超时：返回 false，且不进最近错误', () async {
      installThrowing(TimeoutException('2s 探测超时'));

      expect(await AiClient.instance.isDesktopOnline(force: true), isFalse);

      expect(AppLog.instance.count, 0);
    });

    test('非预期异常：返回 false，但仍记录 ai.health（不掩盖真问题）', () async {
      installThrowing(const HandshakeException('证书不匹配'));

      expect(await AiClient.instance.isDesktopOnline(force: true), isFalse);

      expect(AppLog.instance.count, 1);
      expect(AppLog.instance.latest!.scope, 'ai.health');
    });

    test('失败结果仍走 30s 缓存：不重复探测、不重复留痕', () async {
      final sends = installThrowing(const SocketException('Connection refused'));

      expect(await AiClient.instance.isDesktopOnline(force: true), isFalse);
      // 不带 force：30s 内命中缓存，即使电脑端此刻已启动也不会再探测
      expect(await AiClient.instance.isDesktopOnline(), isFalse);

      expect(sends(), 1, reason: '缓存期内只允许探测一次');
      expect(AppLog.instance.count, 0);
    });
  });
}

class _ThrowingClient extends http.BaseClient {
  _ThrowingClient(this._error, this._onSend);

  final Object _error;
  final void Function() _onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _onSend();
    return Future<http.StreamedResponse>.error(_error);
  }

  @override
  void close() {}
}
