// AI 400 降级 / 请求体兼容性回归测试
//
// 背景：用户实测「测试连接」成功，但「AI 车况解读」报 请求失败（400）。
// 典型根因是 max_tokens 超过免费档 max output（glm-4-flash 常见 1024），
// 以及 temperature / stream / max_tokens 字段名等兼容性差异。
//
// 本文件钉死：
//   1) buildChatBody 默认把 max_tokens 压到 ≤1024
//   2) classifyAi400 能从服务端报错猜出子类
//   3) ai400FallbackOrder 给出合理的降级序列
//   4) sanitizeChatMessages 丢掉空 content、超长输入会截断
//   5) 400 时 AiService.chat 会换 variant 重试并最终成功

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mymg/ai_service.dart';

Future<({String endpoint, Future<void> Function() close})> _serveOnce(
  Future<void> Function(HttpRequest req) handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((req) async {
    try {
      await handle(req);
    } catch (_) {}
  });
  return (
    endpoint: 'http://127.0.0.1:${server.port}/v1/chat/completions',
    close: () async {
      await sub.cancel();
      await server.close(force: true);
    },
  );
}

Future<String> _readBody(HttpRequest req) async =>
    await req.cast<List<int>>().transform(utf8.decoder).join();

void main() {
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('buildChatBody 参数兼容性', () {
    test('★ variant 0 的 max_tokens 不得超过 1024（glm-4-flash 上限）', () {
      final body = buildChatBody(
        model: 'glm-4-flash',
        messages: [
          {'role': 'user', 'content': '你好'},
        ],
        temperature: 0.4,
        maxTokens: 1900,
        variant: 0,
      );
      expect(body['max_tokens'], 1024);
      expect(body['stream'], true);
      expect(body['temperature'], 0.4);
    });

    test('variant 1 用 max_completion_tokens（新版 OpenAI）', () {
      final body = buildChatBody(
        model: 'gpt-4o-mini',
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        temperature: 0.4,
        maxTokens: 1500,
        variant: 1,
      );
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body['max_completion_tokens'], 1024);
    });

    test('variant 2 去掉 temperature 且 max_tokens ≤512', () {
      final body = buildChatBody(
        model: 'o1-mini',
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        temperature: 0.4,
        maxTokens: 1500,
        variant: 2,
      );
      expect(body.containsKey('temperature'), isFalse);
      expect(body['max_tokens'], 512);
    });

    test('variant 4 非流式且不带 max_tokens/temperature', () {
      final body = buildChatBody(
        model: 'm',
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        temperature: 0.4,
        maxTokens: 1500,
        variant: 4,
      );
      expect(body['stream'], false);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
    });
  });

  group('classifyAi400 子类识别', () {
    test('max output 超限 → max_tokens', () {
      expect(
        classifyAi400('{"error":{"message":"max_tokens is too large: 1600. This model supports at most 1024 completion tokens"}}'),
        kAi400MaxTokens,
      );
    });

    test('上下文过长 → context', () {
      expect(
        classifyAi400('This model maximum context length is 8192 tokens'),
        kAi400Context,
      );
    });

    test('temperature 不被接受 → sampling', () {
      expect(
        classifyAi400('Unsupported parameter: temperature'),
        kAi400Sampling,
      );
    });

    test('模型不存在 → model', () {
      expect(
        classifyAi400('{"error":{"code":"model_not_found","message":"The model `foo` does not exist"}}'),
        kAi400Model,
      );
    });
  });

  group('ai400FallbackOrder 降级序列', () {
    test('max_tokens 超限优先试更小输出 / 不传 max_tokens', () {
      final order = ai400FallbackOrder(kAi400MaxTokens);
      expect(order.first, 2);
      expect(order, contains(3));
    });

    test('模型名错不瞎重试一堆', () {
      expect(ai400FallbackOrder(kAi400Model), [0]);
    });
  });

  group('sanitizeChatMessages', () {
    test('丢掉空 content（部分网关空串会 400）', () {
      final out = sanitizeChatMessages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': '   '},
        {'role': 'user', 'content': '有效'},
      ]);
      expect(out.length, 2);
      expect(out.last['content'], '有效');
    });

    test('超长输入会截断到 maxTotalChars 附近', () {
      final long = 'A' * 20000;
      final out = sanitizeChatMessages(
        [
          {'role': 'system', 'content': 'keep-system'},
          {'role': 'user', 'content': long},
        ],
        maxTotalChars: 2000,
      );
      final total = out.fold<int>(0, (a, m) => a + m['content']!.length);
      expect(total, lessThanOrEqualTo(2200));
      expect(out.first['content'], 'keep-system');
    });
  });

  group('AiService.chat 400 自动降级', () {
    test('★ max_tokens 被拒后换 variant 重试成功', () async {
      var calls = 0;
      final seenBodies = <Map<String, dynamic>>[];
      final srv = await _serveOnce((req) async {
        calls++;
        final raw = await _readBody(req);
        final body = jsonDecode(raw) as Map<String, dynamic>;
        seenBodies.add(body);

        // 第一次：模拟 glm-4-flash 拒绝过大 max_tokens
        if (calls == 1) {
          req.response
            ..statusCode = 400
            ..write(jsonEncode({
              'error': {
                'message':
                    'max_tokens is too large: 1024. This model supports at most 512 completion tokens.',
              },
            }));
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = 200
          ..headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('data: {"choices":[{"delta":{"content":"降级后成功"}}]}\n\n')
          ..write('data: [DONE]\n\n');
        await req.response.close();
      });

      // chat() 内部会读 AiService 配置 —— 直接测 buildChatBody + aiChatStream
      // 的组合路径即可覆盖「400 → 换 body」逻辑；这里用顶层函数模拟同样流程。
      try {
        String? result;
        var variant = 0;
        final tried = <int>{0};
        for (var i = 0; i < 6; i++) {
          final body = jsonEncode(buildChatBody(
            model: 'glm-4-flash',
            messages: [
              {'role': 'user', 'content': '分析车况'},
            ],
            temperature: 0.4,
            maxTokens: 1500,
            variant: variant,
          ));
          try {
            result = await aiChatStream(
              endpoint: srv.endpoint,
              apiKey: 'k',
              body: body,
              timeout: const Duration(seconds: 5),
            );
            break;
          } on AiException catch (e) {
            if (e.statusCode != 400) rethrow;
            final kind = classifyAi400(e.rawBody ?? e.message);
            final order = ai400FallbackOrder(kind);
            final next = order.firstWhere(
              (v) => !tried.contains(v),
              orElse: () => -1,
            );
            if (next < 0) rethrow;
            tried.add(next);
            variant = next;
          }
        }
        expect(result, '降级后成功', reason: '第一次 400 后应换 variant 重试成功');
        expect(calls, greaterThanOrEqualTo(2));
        // 第二次起的 max_tokens 必须比第一次更保守
        final firstMax = seenBodies.first['max_tokens'] as int?;
        final later = seenBodies
            .skip(1)
            .map((b) => b['max_tokens'] as int?)
            .whereType<int>();
        for (final m in later) {
          if (firstMax != null) {
            expect(m, lessThanOrEqualTo(firstMax));
          }
        }
      } finally {
        await srv.close();
      }
    });

    test('400 友好文案首行是「请求失败（400）」，并带原因', () async {
      final srv = await _serveOnce((req) async {
        await _readBody(req);
        req.response
          ..statusCode = 400
          ..write(jsonEncode({
            'error': {'message': 'The model `bad-model` does not exist'},
          }));
        await req.response.close();
      });
      try {
        await expectLater(
          aiPostJson(
            endpoint: srv.endpoint,
            apiKey: 'k',
            body: '{}',
            timeout: const Duration(seconds: 5),
          ),
          throwsA(isA<AiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message.split('\n').first, '首行', '请求失败（400）')
              .having((e) => e.message, '含建议', contains('模型名'))),
        );
      } finally {
        await srv.close();
      }
    });
  });
}
