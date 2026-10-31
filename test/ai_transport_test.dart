// AI 传输层回归测试
//
// 背景：用户实测智谱 `open.bigmodel.cn/api/paas/v4/chat/completions` 报
//   HttpException: Software caused connection abort
// 「测试连接」（小 body）能通过，「AI 车况解读」（大 body）失败 —— 典型的
// 「网关卡住分块请求」特征。
//
// 根因：Dart 的 HttpClientRequest 只调 add() 而不设 contentLength 时，
// 会退化成 `Transfer-Encoding: chunked`。本文件用本地 HttpServer 把这个
// 行为**钉死**：一旦有人删掉 `req.contentLength = ...`，测试立刻变红。
//
// 第二轮（同样的报错又出现一次）加了流式传输：
//   非流式时模型要生成十几秒才吐第一个字节，中间连接是静默的，
//   很容易被 NAT/网关按空闲超时掐断。改成 SSE 之后 token 持续回流，
//   且万一半途断了还能保住已生成的部分（见 AiService.chat）。
//   本文件同时钉死：流式请求也得带 Content-Length、SSE 分片要按序累积、
//   对端不是 SSE 时要能退回非流式解析。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/ai_service.dart';

/// 起一个只会服务一次请求的本地服务器，把收到的请求交给 [handle] 处理。
///
/// 返回 (baseUrl, close)。
Future<({String endpoint, Future<void> Function() close})> _serveOnce(
  Future<void> Function(HttpRequest req) handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((req) async {
    try {
      await handle(req);
    } catch (_) {
      // 测试里忽略
    }
  });
  return (
    endpoint: 'http://127.0.0.1:${server.port}/v1/chat/completions',
    close: () async {
      await sub.cancel();
      await server.close(force: true);
    },
  );
}

/// 把请求体读完（否则服务器端可能提前关连接）
Future<String> _readBody(HttpRequest req) async =>
    // HttpRequest 是 Stream<Uint8List>，utf8.decoder 要 Stream<List<int>>
    await req.cast<List<int>>().transform(utf8.decoder).join();

void main() {
  // ★ 不要调用 TestWidgetsFlutterBinding.ensureInitialized()：
  //   它会装上 Flutter 的 mock HttpOverrides，让**所有** HTTP 请求
  //   直接返回 400（"no network request will actually be made"），
  //   本地 HttpServer 也就永远收不到请求。显式清空 overrides 再跑真实 socket。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('aiPostJson 传输行为', () {
    test('★ 必须带 Content-Length，不能退化成 chunked（网关掐断的根因）', () async {
      final body = jsonEncode({
        'model': 'glm-4-flash',
        'messages': [
          {'role': 'user', 'content': '你好' * 500}, // 故意做大，逼近真实分析请求
        ],
      });

      int? seenContentLength;
      var sawChunked = false;

      final srv = await _serveOnce((req) async {
        seenContentLength = req.headers.contentLength;
        sawChunked = req.headers.value('transfer-encoding') == 'chunked';
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '正常'}
              }
            ],
          }));
        await req.response.close();
      });

      try {
        final raw = await aiPostJson(
          endpoint: srv.endpoint,
          apiKey: 'test-key',
          body: body,
          timeout: const Duration(seconds: 10),
        );
        expect(raw, contains('正常'));

        // 核心断言
        expect(sawChunked, isFalse, reason: '不能使用 Transfer-Encoding: chunked');
        expect(seenContentLength, isNotNull, reason: '必须显式设置 Content-Length');
        expect(seenContentLength, utf8.encode(body).length,
            reason: 'Content-Length 必须等于 UTF-8 字节数（不是字符数）');
      } finally {
        await srv.close();
      }
    });

    test('5xx / 429 标记为可重试', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 500
          ..write('{"error":{"message":"upstream busy"}}');
        await req.response.close();
      });
      try {
        await expectLater(
          aiPostJson(
            endpoint: srv.endpoint,
            apiKey: 'k',
            body: '{}',
            timeout: const Duration(seconds: 10),
          ),
          throwsA(isA<AiException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.statusCode, 'statusCode', 500)),
        );
      } finally {
        await srv.close();
      }
    });

    test('401 不标记可重试（重试无意义）', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 401
          ..write('{"error":{"message":"invalid api key"}}');
        await req.response.close();
      });
      try {
        await expectLater(
          aiPostJson(
            endpoint: srv.endpoint,
            apiKey: 'bad',
            body: '{}',
            timeout: const Duration(seconds: 10),
          ),
          throwsA(isA<AiException>()
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.statusCode, 'statusCode', 401)),
        );
      } finally {
        await srv.close();
      }
    });

    test('连接被对端掐断 → 归类为可重试的连接中断', () async {
      final srv = await _serveOnce((req) async {
        // 模拟网关：读完请求头/体直接 RST，不给任何响应
        await _readBody(req);
        req.response.detachSocket().then((s) => s.destroy());
      });
      try {
        await expectLater(
          aiPostJson(
            endpoint: srv.endpoint,
            apiKey: 'k',
            body: '{"a":1}',
            timeout: const Duration(seconds: 10),
          ),
          throwsA(isA<AiException>().having((e) => e.retryable, 'retryable', isTrue)),
        );
      } finally {
        await srv.close();
      }
    });
  });

  group('aiChatStream 流式传输（主流程走的路径）', () {
    test('★ 流式请求同样必须带 Content-Length（不能因为 stream 又退回 chunked）', () async {
      final body = jsonEncode({
        'model': 'glm-4-flash',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': '你好' * 800},
        ],
      });

      int? seenContentLength;
      var sawChunked = false;
      String? seenAccept;

      final srv = await _serveOnce((req) async {
        seenContentLength = req.headers.contentLength;
        sawChunked = req.headers.value('transfer-encoding') == 'chunked';
        seenAccept = req.headers.value(HttpHeaders.acceptHeader);
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('data: {"choices":[{"delta":{"content":"正常"}}]}\n\n')
          ..write('data: [DONE]\n\n');
        await req.response.close();
      });

      try {
        final text = await aiChatStream(
          endpoint: srv.endpoint,
          apiKey: 'k',
          body: body,
          timeout: const Duration(seconds: 10),
        );
        expect(text, '正常');
        expect(sawChunked, isFalse, reason: '流式也不能用 Transfer-Encoding: chunked');
        expect(seenContentLength, utf8.encode(body).length);
        expect(seenAccept, contains('text/event-stream'));
      } finally {
        await srv.close();
      }
    });

    test('逐片累积 SSE delta，并按顺序回调 onDelta', () async {
      const pieces = ['### 一句话结论\n', '油量充足，', '轮胎正常。'];
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        for (final p in pieces) {
          req.response.write(
              'data: ${jsonEncode({'choices': [
                {
                  'delta': {'content': p}
                }
              ]})}\n\n');
          await req.response.flush();
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      try {
        final seen = <String>[];
        final text = await aiChatStream(
          endpoint: srv.endpoint,
          apiKey: 'k',
          body: '{}',
          timeout: const Duration(seconds: 10),
          onDelta: seen.add,
        );
        expect(text, pieces.join());
        expect(seen.length, 3);
        expect(seen.last, pieces.join(), reason: 'onDelta 给的是"累计到现在"的全文');
      } finally {
        await srv.close();
      }
    });

    test('流里夹带 error 负载 → 抛出服务端错误', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('data: {"error":{"message":"rate limited"}}\n\n');
        await req.response.close();
      });
      try {
        await expectLater(
          aiChatStream(
            endpoint: srv.endpoint,
            apiKey: 'k',
            body: '{}',
            timeout: const Duration(seconds: 10),
          ),
          throwsA(isA<AiException>()
              .having((e) => e.message, 'message', contains('rate limited'))),
        );
      } finally {
        await srv.close();
      }
    });

    test('对端没走 SSE（老网关/错误响应）→ 退回非流式结构解析', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'choices': [
              {
                'message': {'content': '非流式也能用'}
              }
            ],
          }));
        await req.response.close();
      });
      try {
        final text = await aiChatStream(
          endpoint: srv.endpoint,
          apiKey: 'k',
          body: '{}',
          timeout: const Duration(seconds: 10),
        );
        expect(text, '非流式也能用');
      } finally {
        await srv.close();
      }
    });

    test('流到一半被掐断（不再有数据）→ 抛出可重试错误，上层据此决定"要不要交半成品"', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('data: {"choices":[{"delta":{"content":"已经开始生成了"}}]}\n\n');
        await req.response.flush();
        // 模拟网关：吐了一片之后直接 RST，后面永远没数据了
        final socket = await req.response.detachSocket();
        socket.destroy();
      });
      try {
        await expectLater(
          aiChatStream(
            endpoint: srv.endpoint,
            apiKey: 'k',
            body: '{}',
            // 压到 2s：被掐断后表现可能是"读到一半断"或"下一片永远等不到"，
            // 两种都必须归类成可重试错误；顺便别让用例白等 10 秒
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<AiException>().having((e) => e.retryable, 'retryable', isTrue)),
        );
      } finally {
        await srv.close();
      }
    });
  });

  group('ChatCompletion 响应解析（走 aiPostJson 全链路）', () {
    Future<String> roundTrip(Object responseJson) async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(responseJson));
        await req.response.close();
      });
      try {
        return await aiPostJson(
          endpoint: srv.endpoint,
          apiKey: 'k',
          body: '{}',
          timeout: const Duration(seconds: 10),
        );
      } finally {
        await srv.close();
      }
    }

    test('标准 choices[0].message.content', () async {
      final raw = await roundTrip({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '体检完成'}
          }
        ],
      });
      expect(raw, contains('体检完成'));
    });

    test('中文内容不被截断（UTF-8 往返正确）', () async {
      const text = '### 一句话结论\n油量充足，轮胎正常。夏季胎压会随气温上升 10~15 kPa，属正常现象。';
      final raw = await roundTrip({
        'choices': [
          {
            'message': {'content': text}
          }
        ],
      });
      expect(raw, contains('胎压会随气温上升'));
      expect(raw, contains('属正常现象'));
    });
  });
}
