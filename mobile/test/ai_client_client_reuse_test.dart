import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// O06 回归：HTTP 客户端要**复用**。
///
/// 原实现里每个请求都 http.Client() … close()；批量处理 160 条消息就是
/// 160 次 TLS 握手。现在整个 AiClient 复用一个实例，关闭时才丢弃重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int created;
  late List<_FakeHttpClient> fakes;

  /// 装一个可计数的 fake client 工厂。
  void installFake(
      Future<http.StreamedResponse> Function(http.BaseRequest) handler) {
    created = 0;
    fakes = <_FakeHttpClient>[];
    AiClient.clientFactory = () {
      created++;
      final c = _FakeHttpClient(handler);
      fakes.add(c);
      return c;
    };
  }

  setUp(() {
    AiClient.secretStore = InMemorySecretStore();
    SharedPreferences.setMockInitialValues({});
    AiClient.instance.closeClient(); // 清掉上一个用例可能留下的实例
  });

  tearDown(() {
    AiClient.instance.closeClient();
    AiClient.clientFactory = () => http.Client();
  });

  test('连续两次请求只创建 1 个 client（health 探测路径）', () async {
    installFake((req) async => _json(200, '{"ok":true}'));

    expect(await AiClient.instance.isDesktopOnline(force: true), isTrue);
    expect(await AiClient.instance.isDesktopOnline(force: true), isTrue);

    expect(created, 1, reason: '两次探测必须复用同一个 client');
    expect(fakes.single.sendCount, 2, reason: '两次探测都走了同一个实例');
  });

  test('关闭后不复用已关闭实例（重新创建）', () async {
    installFake((req) async => _json(200, '{"ok":true}'));

    await AiClient.instance.isDesktopOnline(force: true);
    expect(created, 1);

    AiClient.instance.closeClient();
    expect(fakes.single.closed, isTrue, reason: 'close() 要真正关掉实例');

    await AiClient.instance.isDesktopOnline(force: true);
    expect(created, 2, reason: '关闭后必须重建，不能复用已关闭的 client');
    expect(fakes.last.closed, isFalse);
  });
}

http.StreamedResponse _json(int code, String body) => http.StreamedResponse(
    Stream.value(utf8.encode(body)), code,
    headers: {'content-type': 'application/json'});

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;
  int sendCount = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    return _handler(request);
  }

  @override
  void close() {
    closed = true;
  }
}
