// AI 服务层（路线 A 增强 · Day 7）
//
// 统一收口所有「把车况数据交给大模型做智能分析」的调用：
//   1) 历史数据变化总结（history_page）
//   2) 当前车况体检 / 智能解读（home_page）
//   3) 告警解读（并入体检 prompt）
//
// 设计要点：
//   - 只依赖 OpenAI 兼容的 `POST {baseUrl}/chat/completions`，
//     因此 DeepSeek / 通义千问 / Kimi / 智谱 GLM / OpenAI / 自建 One-API 都能直接用。
//   - **零新增 pub 依赖**：HTTP 用 dart:io 的 HttpClient 手写，
//     避免为了一个 POST 引入 http / dio。
//   - baseUrl / model / 开关 存 SharedPreferences；
//     **apiKey 存 flutter_secure_storage**（Android KeyStore 加密，不明文落盘、不进云备份）。
//
// ⚠️ release 包必须在 AndroidManifest 声明 INTERNET 权限：
//    Flutter 只在 debug/profile 的 manifest 里加了 INTERNET，
//    release 不会自动带 —— 否则打出来的 release 包连不上任何网络（含车况接口）。已补。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mymg/src/rust/vehicle/summary.dart';

import 'coord.dart';
import 'doh_resolver.dart';
import 'store.dart';

/// 常见 OpenAI 兼容服务商预设（一键填充 baseUrl + model）
class AiPreset {
  const AiPreset(this.name, this.baseUrl, this.model, {this.note});
  final String name;
  final String baseUrl;
  final String model;
  final String? note;
}

const kAiPresets = <AiPreset>[
  AiPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat',
      note: '便宜好用，中文强，推荐首选'),
  AiPreset('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'qwen-plus',
      note: '阿里云百炼，兼容模式'),
  AiPreset('Kimi', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k',
      note: '月之暗面 Moonshot'),
  AiPreset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash',
      note: 'glm-4-flash 免费额度大'),
  AiPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
];

/// AI 配置
class AiConfig {
  const AiConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.enabled = true,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final bool enabled;

  bool get isConfigured =>
      enabled && baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  AiConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? enabled,
  }) =>
      AiConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        enabled: enabled ?? this.enabled,
      );

  /// 拼出最终的 chat completions 端点（容忍用户填了/没填 /v1、结尾斜杠）
  String get endpoint {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/chat/completions')) return b;
    return '$b/chat/completions';
  }
}

/// AI 调用失败（网络 / 鉴权 / 限流 / 解析），带可读中文信息
class AiException implements Exception {
  AiException(
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.dnsFailure = false,
    this.rawBody,
  });
  final String message;
  final int? statusCode;

  /// 是否是"再试一次可能就好了"的错误（连接被中断 / 超时 / 5xx）。
  /// 鉴权失败、路径写错这类重试没意义，标 false。
  final bool retryable;

  /// 是否是**本机域名解析失败**（`Failed host lookup`）。
  /// 这类错误换网络/换 DNS 才有用，[AiService.chat] 会据此改用备用 DNS 重试。
  final bool dnsFailure;

  /// 服务端原始响应体（诊断 / 400 子类判定用；可能为空）
  final String? rawBody;

  @override
  String toString() => message;
}

/// 把 SocketException 转成人话。
///
/// [AiService.chat] 会看 [AiException.dnsFailure] 决定要不要换备用 DNS 再来一次，
/// 所以这里必须把"解析失败"和"真的不通"分开 —— 前者应用层还能自救，
/// 后者只能提示用户换网络。
AiException _socketError(SocketException e) {
  if (isHostLookupFailure(e)) {
    return AiException(
      '域名解析失败：${e.message}\n'
      '这是**本机 DNS** 的问题，不是 API Key 或接口地址写错。\n'
      '常见原因：开了 VPN / 加速器 / 广告拦截 App，或系统设了「私人 DNS」。\n'
      '已自动改用备用 DNS 重试一次。',
      retryable: true,
      dnsFailure: true,
    );
  }
  return AiException(
    '网络不通：${e.message}\n请检查接口地址、是否联网、或是否需要代理。',
    retryable: true,
  );
}

/// 每次 AI 请求都**新建**一个 HttpClient，用完 `close(force: true)`。
///
/// 为什么不用共享的长连接池（之前是共享的）：
///   池里的 keep-alive 连接被对端/中间设备悄悄关掉后，复用它会直接抛
///   `HttpException: Software caused connection abort`，而且这种失败
///   "首次能连上、后续偶尔炸"，非常像网络问题，极难排查。
///   AI 调用本身要跑十几秒，省下的那点 TCP/TLS 握手开销可以忽略 ——
///   用可靠性换这点性能是划算的。
///
/// [withDohFallback] 为 true 时挂上备用 DNS 解析（见 doh_resolver.dart），
/// 只在"系统 DNS 已经失败"的重试轮次才开，正常路径完全不受影响。
HttpClient _newHttpClient({bool withDohFallback = false}) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 15);
  if (withDohFallback) {
    c.connectionFactory = connectWithDohFallback;
  }
  return c;
}

/// 组装并发出一次 chat completions POST，返回**已写出请求体**的 request。
///
/// ★ 关键：显式设置 `contentLength`。
///   Dart 的 `HttpClientRequest` 如果只调 `add()` 而不设 contentLength，
///   会退化成 `Transfer-Encoding: chunked`。实测智谱
///   `open.bigmodel.cn/api/paas/v4/chat/completions` 前面那层网关对
///   **较大的分块请求**会直接掐断连接，Dart 侧报的正是
///   `HttpException: Software caused connection abort`。
///   带上定长 Content-Length 走普通请求即可。
Future<HttpClientRequest> _openPost({
  required HttpClient http,
  required String endpoint,
  required String apiKey,
  required String body,
  required Duration timeout,
  required bool stream,
}) async {
  final bytes = utf8.encode(body);
  final req = await http.postUrl(Uri.parse(endpoint)).timeout(timeout);
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
  req.headers.set(
    HttpHeaders.acceptHeader,
    stream ? 'text/event-stream' : 'application/json',
  );
  req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
  req.contentLength = bytes.length; // ★ 见上方说明：这一步把请求从 chunked 变成定长
  req.add(bytes);
  return req;
}

/// 把非 2xx 响应转成人话异常（含 retryable 判定）
AiException _httpError(int code, String raw) => AiException(
      _friendlyHttpError(code, raw),
      statusCode: code,
      // 5xx / 408 / 429 过一会儿可能就好了
      retryable: code >= 500 || code == 408 || code == 429,
      rawBody: raw,
    );

/// 从 400 响应体里猜「具体是哪一类参数问题」，决定降级重试策略。
///
/// 兼容各家 OpenAI 网关的中英文报错关键词；猜不准就走 [kAi400Unknown]。
String classifyAi400(String raw) {
  final low = raw.toLowerCase();
  bool has(List<String> keys) => keys.any(low.contains);

  // max_tokens / max output 超限 —— glm-4-flash 等免费档上限常见 1024
  if (has([
    'max_tokens',
    'max_completion_tokens',
    'max output',
    'max_tokens is too large',
    'maximum output',
    'output tokens',
  ])) {
    return kAi400MaxTokens;
  }
  // 上下文/输入过长
  if (has([
    'context length',
    'context_length',
    'maximum context',
    'too long',
    'token limit',
    'tokens exceeded',
    'exceeds the maximum',
    'input is too long',
    'prompt is too long',
    '请求过长',
    '过长',
  ])) {
    return kAi400Context;
  }
  // temperature / top_p 等采样参数不被接受
  if (has(['temperature', 'top_p', 'top_k', 'unsupported parameter', 'unknown parameter'])) {
    return kAi400Sampling;
  }
  // 模型名不对
  if (has([
    'model_not_found',
    'model not found',
    'invalid model',
    'does not exist',
    'not a valid model',
    'unknown model',
    '模型不存在',
    '模型名',
  ])) {
    return kAi400Model;
  }
  // stream 不被支持 / 参数冲突
  if (has(['stream', 'streaming'])) {
    return kAi400Stream;
  }
  return kAi400Unknown;
}

const kAi400MaxTokens = 'max_tokens';
const kAi400Context = 'context';
const kAi400Sampling = 'sampling';
const kAi400Model = 'model';
const kAi400Stream = 'stream';
const kAi400Unknown = 'unknown';

/// 组装 chat completions 请求体。
///
/// **为什么 max_tokens 先压到 ≤1024**：智谱 glm-4-flash 等免费档
/// max output 常见就是 1024，请求 1600/1900 会直接 400；
/// 而「测试连接」用 max_tokens=32 能通过——大请求失败、小请求成功，
/// 极像网络问题，实际是参数超限。
///
/// [variant] 见 [chatBodyVariants]。
Map<String, Object?> buildChatBody({
  required String model,
  required List<Map<String, String>> messages,
  required double temperature,
  required int maxTokens,
  required int variant,
}) {
  final msgs = sanitizeChatMessages(messages);
  final capped = math.min(maxTokens, 1024);
  final base = <String, Object?>{
    'model': model,
    'messages': msgs,
    'stream': true,
  };
  switch (variant) {
    case 0: // 默认：定长 max_tokens + temperature（覆盖绝大多数兼容端）
      return {
        ...base,
        'temperature': temperature,
        'max_tokens': capped,
      };
    case 1: // 新版 OpenAI：只认 max_completion_tokens
      return {
        ...base,
        'temperature': temperature,
        'max_completion_tokens': capped,
      };
    case 2: // 去掉采样参数 + 更小 max_tokens（推理模型 / 严格网关）
      return {
        ...base,
        'max_tokens': math.min(capped, 512),
      };
    case 3: // 不传 max_tokens，交给服务商默认上限
      return {
        ...base,
        'temperature': temperature,
      };
    case 4: // 最小可用 + 非流式（老网关可能拒 stream）
      return {
        'model': model,
        'messages': msgs,
        'stream': false,
      };
    default: // 兜底：再小一档输出
      return {
        ...base,
        'max_tokens': 256,
      };
  }
}

/// 按 400 子类选出优先尝试的 variant 序列（下标对应 [buildChatBody]）。
List<int> ai400FallbackOrder(String kind) {
  return switch (kind) {
    kAi400MaxTokens => const [2, 3, 4, 5],
    kAi400Context => const [2, 4, 3], // 先缩输出，上层还会截断 messages
    kAi400Sampling => const [2, 3, 4],
    kAi400Stream => const [4, 0],
    kAi400Model => const [0], // 模型名错，重试无意义，保留一次让上层报清晰错误
    _ => const [1, 2, 3, 4],
  };
}

/// 清洗 messages：去掉空 content、过长 user 消息从中间截断。
///
/// 空字符串 content 会被部分网关判 400；超长输入会撞上下文上限。
List<Map<String, String>> sanitizeChatMessages(
  List<Map<String, String>> messages, {
  int maxTotalChars = 9000,
}) {
  final cleaned = <Map<String, String>>[];
  for (final m in messages) {
    final role = (m['role'] ?? 'user').trim();
    final content = (m['content'] ?? '').trim();
    if (content.isEmpty) continue;
    cleaned.add({'role': role, 'content': content});
  }
  if (cleaned.isEmpty) {
    return [
      {'role': 'user', 'content': '请回复：收到'},
    ];
  }

  var total = 0;
  for (final m in cleaned) {
    total += m['content']!.length;
  }
  if (total <= maxTotalChars) return cleaned;

  // 优先保 system，从最后一条 user 往前压
  final out = cleaned
      .map((m) => {'role': m['role']!, 'content': m['content']!})
      .toList();
  for (var i = out.length - 1; i >= 0; i--) {
    if (total <= maxTotalChars) break;
    final role = out[i]['role']!;
    final content = out[i]['content']!;
    if (role == 'system') continue;
    final overflow = total - maxTotalChars;
    if (content.length <= overflow + 80) {
      total -= content.length;
      out[i] = {
        'role': role,
        'content': content.length <= 80 ? content : '${content.substring(0, 80)}…（已截断）',
      };
      total += out[i]['content']!.length;
    } else {
      final keep = content.length - overflow;
      final head = keep ~/ 2;
      final tail = keep - head;
      out[i] = {
        'role': role,
        'content':
            '${content.substring(0, head)}…（中间已截断）…${content.substring(content.length - tail)}',
      };
      total = total - content.length + out[i]['content']!.length;
    }
  }
  return out;
}

/// 向 OpenAI 兼容端点发一次**非流式** POST，返回原始响应体文本。
///
/// 保留它主要是给回归测试与"想看原始 body"的场景用；
/// App 主流程走的是 [aiChatStream]（流式，更不容易被掐断）。
Future<String> aiPostJson({
  required String endpoint,
  required String apiKey,
  required String body,
  Duration timeout = const Duration(seconds: 120),
  HttpClient? client,
}) async {
  final owns = client == null;
  final http = client ?? _newHttpClient();
  try {
    final req = await _openPost(
      http: http,
      endpoint: endpoint,
      apiKey: apiKey,
      body: body,
      timeout: timeout,
      stream: false,
    );
    final resp = await req.close().timeout(timeout);
    final raw = await resp.transform(utf8.decoder).join().timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _httpError(resp.statusCode, raw);
    }
    return raw;
  } on AiException {
    rethrow;
  } on TimeoutException {
    throw AiException(
      '请求超时（>${timeout.inSeconds}s）。可能模型排队或输出太长，稍后重试即可。',
      retryable: true,
    );
  } on HandshakeException catch (e) {
    throw AiException('TLS 握手失败：${e.message}\n若用的是自建网关，检查证书是否受信任。',
        retryable: true);
  } on SocketException catch (e) {
    throw _socketError(e);
  } on HttpException catch (e) {
    // 这就是 "Software caused connection abort" 落到的分支
    throw AiException('连接被中断：${e.message}', retryable: true);
  } on FormatException {
    throw AiException('接口返回的不是 JSON，请确认 baseUrl 指向 OpenAI 兼容端点');
  } finally {
    if (owns) http.close(force: true);
  }
}

/// 以 **SSE 流式**方式请求 chat completions，返回累积出来的完整正文。
///
/// [onDelta] 每收到一段增量文本就回调一次（可用来做打字机效果）。
///
/// 为什么主流程改成流式：
///   非流式请求下，模型要生成十几秒才吐第一个字节，中间这段连接是**静默**的，
///   运营商 NAT / 网关的空闲超时很容易把它掐掉 —— Dart 侧看到的就是
///   `Software caused connection abort`。流式模式下 token 持续回流，
///   连接一直有数据在动，被掐断的概率大幅下降；
///   而且万一真的中途断了，**已收到的部分仍然可用**（见 [AiService.chat]）。
///
/// 兼容性：如果对端压根没走 SSE（错误响应或老网关），这里会把原始 body
/// 整体兜住再按非流式结构解析，不会因为"不是流"就失败。
Future<String> aiChatStream({
  required String endpoint,
  required String apiKey,
  required String body,
  Duration timeout = const Duration(seconds: 180),
  void Function(String soFar)? onDelta,
  HttpClient? client,
  bool useDohDns = false,
}) async {
  final owns = client == null;
  final http = client ?? _newHttpClient(withDohFallback: useDohDns);
  final buf = StringBuffer();
  final passthrough = StringBuffer();
  var sawSse = false;

  try {
    final req = await _openPost(
      http: http,
      endpoint: endpoint,
      apiKey: apiKey,
      body: body,
      timeout: timeout,
      stream: true,
    );
    final resp = await req.close().timeout(timeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final raw = await resp.transform(utf8.decoder).join().timeout(timeout);
      throw _httpError(resp.statusCode, raw);
    }

    final lines = resp
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(timeout); // 逐事件计时：只要 token 还在流，就不会超时

    await for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (!t.startsWith('data:')) {
        // 非 SSE 内容（有些错误响应直接返回一段 JSON），先攒着
        passthrough.write(line);
        continue;
      }
      final payload = t.substring(5).trim();
      if (payload == '[DONE]') break;
      sawSse = true;
      final delta = _deltaText(payload);
      if (delta.isNotEmpty) {
        buf.write(delta);
        onDelta?.call(buf.toString());
      }
    }

    if (!sawSse) {
      final raw = passthrough.toString();
      if (raw.trim().isEmpty) {
        throw AiException('接口没有返回内容（流式响应为空）', retryable: true);
      }
      return _extractContent(raw);
    }
    if (buf.isEmpty) {
      throw AiException('模型返回了空内容，请检查模型名是否正确（当前：$endpoint）');
    }
    return buf.toString();
  } on AiException {
    rethrow;
  } on TimeoutException {
    throw AiException(
      '等待模型输出超时（>${timeout.inSeconds}s 没有新内容）。',
      retryable: true,
    );
  } on HandshakeException catch (e) {
    throw AiException('TLS 握手失败：${e.message}', retryable: true);
  } on SocketException catch (e) {
    throw _socketError(e);
  } on HttpException catch (e) {
    throw AiException('连接被中断：${e.message}', retryable: true);
  } finally {
    if (owns) http.close(force: true);
  }
}

/// 从一条 SSE `data:` 负载里取增量文本。取不到返回空串。
String _deltaText(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    // SSE 被切断时最后一行可能是半截 JSON —— 丢掉这一片即可，不要因此报错
    return '';
  }
  if (decoded is! Map) return '';
  final err = decoded['error'];
  if (err != null) {
    final msg = err is Map ? (err['message'] ?? err.toString()) : err.toString();
    final low = msg.toString().toLowerCase();
    if (low.contains('internal server error') || low.contains('500')) {
      throw AiException(
        'AI 服务商内部错误（500）。请稍后重试，或到「设置 → AI 智能分析」检查接口/模型/密钥。\n原始信息：$msg',
        statusCode: 500,
        retryable: true,
      );
    }
    throw AiException('服务端错误：$msg');
  }
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final first = choices.first;
  if (first is! Map) return '';
  final delta = first['delta'];
  if (delta is Map) {
    final c = delta['content'];
    if (c is String) return c;
    if (c is List) {
      final b = StringBuffer();
      for (final seg in c) {
        if (seg is Map && seg['text'] is String) b.write(seg['text']);
      }
      return b.toString();
    }
  }
  // 少数网关在"流式"里也直接给 message.content
  final msg = first['message'];
  if (msg is Map && msg['content'] is String) return msg['content'] as String;
  final t = first['text'];
  if (t is String) return t;
  return '';
}

String _friendlyHttpError(int code, String raw) {
  String detail = '';
  try {
    final d = jsonDecode(raw);
    if (d is Map) {
      final e = d['error'];
      if (e is Map && e['message'] != null) {
        detail = e['message'].toString();
      } else if (d['message'] != null) {
        detail = d['message'].toString();
      }
    }
  } catch (_) {
    detail = raw.length > 300 ? '${raw.substring(0, 300)}…' : raw;
  }
  // 400 要按子类给可执行建议（模型名 / 上下文 / max_tokens / 采样参数…）
  final head = switch (code) {
    400 => _friendly400(raw, detail),
    401 => 'API Key 无效或已过期（401）',
    402 => '账户余额不足（402）',
    403 => '无权访问该模型（403）',
    404 => '接口路径不存在（404），请检查 baseUrl 是否漏/多了 /v1',
    429 => '触发限流或额度用尽（429）',
    500 || 502 || 503 || 504 => '''
AI 服务商返回了服务端错误（HTTP $code Internal Server Error）
含义：请求已到对方服务器，但对方内部处理失败——通常不是本机网络问题。
可尝试：
1) 稍后重试（可能是临时故障/排队）
2) 到「设置 → AI 智能分析」核对 baseUrl、模型名、API Key
3) 换预设中的其他服务商（如 DeepSeek / 智谱 glm-4-flash）
4) 若用自建/中转网关，确认网关日志里的真实错误''',
    >= 500 => '服务端错误（$code）',
    _ => '请求失败（$code）',
  };
  if (detail.isEmpty || detail.toLowerCase() == 'internal server error') {
    return head;
  }
  // 400 的 detail 可能很长；短到没信息量时不附
  if (code == 400 && detail.length < 8) return head;
  return '$head\n原始响应：$detail';
}

/// 400 的首行固定为「请求失败（400）」——首页状态栏只放第一行，
/// 具体原因/建议放后续行，弹层和 SnackBar 里能看全。
String _friendly400(String raw, String detail) {
  final kind = classifyAi400('$raw\n$detail');
  final tips = switch (kind) {
    kAi400MaxTokens => '输出上限过大（常见于 glm-4-flash 等免费档，max output 仅 1024）。\n'
        'App 已自动降级 max_tokens 重试；若仍失败，请到设置里换 deepseek-chat / qwen-plus。',
    kAi400Context => '上下文/历史过长，超出该模型上限。\n'
        'App 已自动截断后重试；也可改选「最近 24 小时」再分析。',
    kAi400Sampling => '该模型不接受 temperature 等采样参数。\n'
        'App 已去掉采样参数重试；若仍失败，换预设模型（deepseek-chat / glm-4-flash）。',
    kAi400Model => '模型名不对或不存在。\n'
        '请到「设置 → AI 智能分析」核对 model（预设里可一键填 deepseek-chat / glm-4-flash）。',
    kAi400Stream => '该网关不支持 stream 流式输出。\n'
        'App 已改用非流式重试；若仍失败，检查 baseUrl 是否指向 OpenAI 兼容端点。',
    _ => '常见原因：\n'
        '1) 模型名不对（设置里核对 model）\n'
        '2) 上下文/历史过长，超出该模型上限\n'
        '3) max_tokens 超过该模型输出上限（免费档常见 1024）\n'
        '4) baseUrl 与 API Key 不是同一家（OpenAI 兼容协议有差异）\n'
        '可尝试：换短时段重新分析、换预设模型（glm-4-flash / deepseek-chat）、检查接口地址',
  };
  return '请求失败（400）\n$tips';
}

/// 「再次分析」时把**上一次的结论**拼进 prompt 的片段。
///
/// 返回空串表示没有可用作对比的旧结论（null / 太短都算没有）。
/// 单独提成顶层纯函数是为了能单测 —— 「新旧结论怎么合并」是本功能的核心逻辑。
String buildPreviousSection(String? previous) {
  final prev = previous?.trim();
  if (prev == null || prev.length < 20) return '';
  // 老结论可能很长，截断到 1800 字够模型做对比了，避免把 prompt 撑爆
  final shown = prev.length > 1800 ? '${prev.substring(0, 1800)}…' : prev;
  return '## 四、上一次的结论（供对比，不要整段复述）\n$shown\n';
}

/// 从**非流式**响应体里抠出 choices[0].message.content。
///
/// 放在顶层而不是 AiService 里，因为流式函数 [aiChatStream] 在
/// "对端没走 SSE" 的分支里也要用它（顶层函数拿不到类的私有方法）。
String _extractContent(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw AiException('接口返回结构异常');
  final err = decoded['error'];
  if (err != null) {
    final msg = err is Map ? (err['message'] ?? err.toString()) : err.toString();
    final low = msg.toString().toLowerCase();
    if (low.contains('internal server error') || low.contains('500')) {
      throw AiException(
        'AI 服务商内部错误（500）。请稍后重试，或到「设置 → AI 智能分析」检查接口/模型/密钥。\n原始信息：$msg',
        statusCode: 500,
        retryable: true,
      );
    }
    throw AiException('服务端错误：$msg');
  }
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    // 有些网关把内容直接放在 content 或 output_text
    final direct = decoded['content'] ?? decoded['output_text'];
    if (direct is String && direct.trim().isNotEmpty) return direct;
    throw AiException('接口未返回 choices，请确认是 OpenAI 兼容的 chat 接口');
  }
  final first = choices.first;
  if (first is Map) {
    final msg = first['message'];
    if (msg is Map) {
      final c = msg['content'];
      if (c is String) return c;
      // 少数模型返回分段 content 数组
      if (c is List) {
        final buf = StringBuffer();
        for (final seg in c) {
          if (seg is Map && seg['text'] is String) buf.write(seg['text']);
        }
        if (buf.isNotEmpty) return buf.toString();
      }
    }
    final t = first['text'];
    if (t is String) return t;
  }
  throw AiException('无法解析模型返回内容');
}

class AiService {
  AiService._();
  static final AiService instance = AiService._();

  // ── 存储 key ─────────────────────────────────────────────────────────
  static const _kBaseUrl = 'mymg.ai.base_url';
  static const _kModel = 'mymg.ai.model';
  static const _kEnabled = 'mymg.ai.enabled';
  static const _kApiKey = 'mymg.ai.api_key_v1'; // secure storage

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  AiConfig? _cache;

  /// 同步读缓存（UI 首帧用；未 load 过时为 null）
  AiConfig? get cached => _cache;

  /// 读取完整配置（含解密 apiKey）
  Future<AiConfig> load({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    final p = await SharedPreferences.getInstance();
    var key = '';
    try {
      key = await _secure.read(key: _kApiKey) ?? '';
    } catch (e) {
      debugPrint('[MYMG] 读取 AI key 失败: $e');
    }
    final cfg = AiConfig(
      baseUrl: p.getString(_kBaseUrl) ?? '',
      model: p.getString(_kModel) ?? '',
      enabled: p.getBool(_kEnabled) ?? true,
      apiKey: key,
    );
    _cache = cfg;
    return cfg;
  }

  /// 保存配置。apiKey 传 null 表示「不改动已存的 key」。
  Future<void> save({
    String? baseUrl,
    String? model,
    bool? enabled,
    String? apiKey,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (baseUrl != null) await p.setString(_kBaseUrl, baseUrl.trim());
    if (model != null) await p.setString(_kModel, model.trim());
    if (enabled != null) await p.setBool(_kEnabled, enabled);
    if (apiKey != null) {
      if (apiKey.isEmpty) {
        await _secure.delete(key: _kApiKey);
      } else {
        await _secure.write(key: _kApiKey, value: apiKey.trim());
      }
    }
    await load(force: true);
  }

  /// apiKey 脱敏预览（设置页展示用）
  Future<String> maskedKey() async {
    final cfg = await load();
    final k = cfg.apiKey;
    if (k.isEmpty) return '';
    if (k.length <= 10) return '*' * k.length;
    return '${k.substring(0, 6)}${'*' * 6}${k.substring(k.length - 4)}';
  }

  // ── HTTP 核心 ────────────────────────────────────────────────────────

  /// 调一次 chat completions。messages 为 [{role, content}]。
  ///
  /// 走**流式**传输（`stream: true`）：token 持续回流，连接不会长时间静默，
  /// 明显降低"被网关/NAT 掐断"的概率。
  ///
  /// 容错策略：
  ///   1. 已经生成了一大段（≥ [partialMinChars]）却中途断掉 →
  ///      **把半成品直接返回**（附一行说明），比弹一个错误有用得多；
  ///   2. 断得太早（几乎没内容）→ 判定为可重试错误，换一条新连接再来一次；
  ///   3. 鉴权失败 / 路径写错这类重试无意义的错误不重试。
  /// [onDelta] 每收到一段增量文本就回调一次 —— 弹层拿它做"边生成边显示"，
  /// 这是"感觉慢"的主要解药：等 15 秒出全文 vs 0.5 秒就开始滚字，体感完全不同。
  Future<String> chat(
    List<Map<String, String>> messages, {
    double temperature = 0.4,
    int maxTokens = 1500,
    Duration timeout = const Duration(seconds: 180),
    int attempts = 3,
    int partialMinChars = 120,
    void Function(String soFar)? onDelta,
  }) async {
    final cfg = await load();
    if (!cfg.isConfigured) {
      throw AiException('AI 未配置：请到「设置 → AI 智能分析」填写接口地址与 API Key');
    }
    final model = cfg.model.trim().isEmpty ? 'deepseek-chat' : cfg.model.trim();

    // 首选 variant 0（max_tokens ≤1024 + temperature）；
    // 400 时按服务端报错切换 1/2/3/4（见 classifyAi400 / ai400FallbackOrder）。
    var msgs = sanitizeChatMessages(messages);
    var variant = 0;
    var triedVariants = <int>{0};

    AiException? last;
    // 是否已经切到"备用 DNS 直连"通道（只在系统 DNS 失败后启用一次）
    var triedDoh = false;
    for (var i = 0; i < attempts + 4; i++) {
      final body = jsonEncode(buildChatBody(
        model: model,
        messages: msgs,
        temperature: temperature,
        maxTokens: maxTokens,
        variant: variant,
      ));
      // 每次重试都重新收集，避免把上一次的残留拼进来
      final buf = StringBuffer();
      try {
        final text = await aiChatStream(
          endpoint: cfg.endpoint,
          apiKey: cfg.apiKey,
          body: body,
          timeout: timeout,
          useDohDns: triedDoh,
          onDelta: (soFar) {
            // 内部先攒一份（断线时当半成品返回），再转发给调用方做打字机效果
            buf
              ..clear()
              ..write(soFar);
            onDelta?.call(soFar);
          },
        );
        final trimmed = text.trim();
        if (trimmed.isEmpty) {
          throw AiException('模型返回了空内容，请检查模型名是否正确（当前：$model）');
        }
        return trimmed;
      } on AiException catch (e) {
        last = e;

        // ★ 域名解析失败：立刻换成"自己查 DNS 再拿 IP 直连"的通道重试一次。
        //   系统 DNS 坏掉时（私人 DNS / VPN / 加速器 / 运营商故障）
        //   这是唯一能自愈的路子，且不会影响正常的解析路径。
        if (e.dnsFailure && !triedDoh && i < attempts - 1) {
          triedDoh = true;
          debugPrint('[MYMG] 域名解析失败，改用备用 DNS（DoH）重试');
          continue; // 跳过退避：这不是"服务器忙"，换个解析通道立刻试
        }

        // ★ 半成品也算成果：长内容生成到一半被掐断时，直接交给用户
        final partial = buf.toString().trim();
        if (partial.length >= partialMinChars) {
          debugPrint('[MYMG] AI 流式中断，但已收到 ${partial.length} 字，返回部分内容');
          return '$partial\n\n---\n'
              '（连接在中途被中断，以上是已生成的部分内容；再点一次可继续补全）';
        }

        // ★ 400 Bad Request：按服务端原因换一种请求体再试（参数兼容性问题，
        //   不是"服务器忙"，不必退避）。这是 glm-4-flash 等免费档
        //   「测试连接成功、AI 车况解读 400」的主修复路径。
        //   子类判定用 rawBody（友好文案里含「max_tokens」等建议词，会误判）。
        if (e.statusCode == 400) {
          // 子类判定优先用 rawBody（友好文案会复述「max_tokens」等建议词，会误判）
          final rawKind = e.rawBody == null || e.rawBody!.trim().isEmpty
              ? kAi400Unknown
              : classifyAi400(e.rawBody!);
          final useKind = rawKind == kAi400Unknown
              ? classifyAi400('${e.rawBody ?? ''}\n${e.message}')
              : rawKind;
          final order = ai400FallbackOrder(useKind);
          final next = order.firstWhere(
            (v) => !triedVariants.contains(v),
            orElse: () => -1,
          );
          if (next >= 0) {
            triedVariants.add(next);
            variant = next;
            // 上下文过长：同步截断 messages
            if (useKind == kAi400Context) {
              msgs = sanitizeChatMessages(msgs, maxTotalChars: 4000);
            }
            debugPrint('[MYMG] AI 400（$useKind），降级 variant=$next 重试');
            continue;
          }
          // 所有 variant 都试过了 → 抛出带建议的 400
          rethrow;
        }

        if (!e.retryable || i >= attempts - 1) {
          // 备用 DNS 也救不回来 → 说明本机网络的 DNS 被彻底限制住了，
          // 给一份能直接照着做的收尾提示，别只说"网络不通"。
          if (e.dnsFailure && triedDoh) {
            throw AiException(
              '${e.message}\n'
              '备用 DNS（223.5.5.5 / 119.29.29.29）同样解析不到，'
              '基本可以确定是本机网络的 DNS 被限制了。\n'
              '建议：① 关掉 VPN / 加速器 / 广告拦截后重试；'
              '②「设置 → 网络和互联网 → 私人 DNS」改成「自动」或「关闭」；'
              '③ 换个网络再试（Wi-Fi ⇄ 流量）。',
              statusCode: e.statusCode,
              retryable: true,
              dnsFailure: true,
            );
          }
          rethrow;
        }
        debugPrint('[MYMG] AI 调用失败将重试（第 ${i + 1} 次）：${e.message}');
      } catch (e) {
        // 兜底：_extractContent 的 FormatException 等
        last = AiException(e is FormatException
            ? '接口返回的不是 JSON，请确认 baseUrl 指向 OpenAI 兼容端点'
            : e.toString());
        if (i >= attempts - 1) throw last;
      }
      // 稍等再试：给对端一个释放旧连接的时间
      await Future.delayed(Duration(milliseconds: 700 * (i + 1)));
    }
    throw last ?? AiException('请求失败');
  }

  /// 「测试连接」用：发一条极短的请求验证配置可用
  Future<String> testConnection() async {
    final r = await chat(
      const [
        {'role': 'user', 'content': '请只回复两个字：正常'},
      ],
      temperature: 0,
      maxTokens: 32,
      timeout: const Duration(seconds: 30),
    );
    return r;
  }

  // ── 场景 1：历史数据变化总结 ─────────────────────────────────────────

  /// 分析历史快照的「变化项」，交给大模型产出中文总结。
  ///
  /// [rows] 传时间**倒序**（最新在前）的原始列表即可，内部自己排。
  Future<String> analyzeHistory(
    List<SnapshotRow> rows, {
    String? vin,
    void Function(String soFar)? onDelta,
  }) async {
    if (rows.isEmpty) {
      throw AiException('本机还没有历史快照，先在主页下拉刷新几次再来分析');
    }
    final asc = rows.reversed.toList(growable: false);
    final prompt = _buildHistoryPrompt(asc, vin: vin);
    return chat(
      [
        {
          'role': 'system',
          'content':
              '你是资深汽车管家兼数据分析师，服务对象是一台 2021 款名爵 MG5（1.5L 燃油车）。'
              '你会收到一段车况时序数据，请**只依据给定数据**做分析，不要编造数据中不存在的结论。'
              '输出用简体中文、Markdown 风格（可分点、可用小标题），控制在 600 字以内。'
              '必须包含这四块：\n'
              '### 一句话结论\n'
              '### 变化要点（逐项：现象 → 可能原因）\n'
              '### 异常提醒（没有异常就写「未发现异常」，不要硬凑）\n'
              '### 用车建议（2~4 条，可执行、具体）\n'
              '数值请带单位，百分比变化请同时给出绝对变化量。',
        },
        {'role': 'user', 'content': prompt},
      ],
      temperature: 0.35,
      // 1024 对齐 glm-4-flash 等免费档 max output，避免「测试连接成功、
      // 真分析 400」；600 字中文约 700~1100 token，够用。
      maxTokens: 1024,
      onDelta: onDelta,
    );
  }

  /// 把时序数据压缩成「关键变化 + 抽样明细」，控制 token 又不丢信息。
  String _buildHistoryPrompt(List<SnapshotRow> asc, {String? vin}) {
    final first = asc.first;
    final last = asc.last;

    num? delta(num? a, num? b) =>
        (a == null || b == null) ? null : (b - a);

    final fuelDelta = delta(first.fuelPercent, last.fuelPercent);
    final rangeDelta = delta(first.rangeKm, last.rangeKm);
    final odoDelta = delta(first.odometerKm, last.odometerKm);

    final interiorTemps =
        asc.map((e) => e.interiorTemp).whereType<double>().toList();
    final exteriorTemps =
        asc.map((e) => e.exteriorTemp).whereType<double>().toList();

    // 位置变化次数（用 5 位小数 ≈ 1m 精度判同一位置）
    String? prevLoc;
    var moves = 0;
    for (final r in asc) {
      final loc = '${r.latitude ?? ''},${r.longitude ?? ''}';
      if (r.latitude == null || r.longitude == null) continue;
      if (prevLoc != null && loc != prevLoc) moves++;
      prevLoc = loc;
    }

    // 总里程差 → 期间行驶里程（比 journey 字段更可靠：journey 是「本次行程」）
    final driven = odoDelta;

    final sb = StringBuffer()
      ..writeln('【车辆】2021 款名爵 MG5 · 燃油（45L 油箱）')
      ..writeln(
          '【VIN 后 6 位】${vin != null && vin.length >= 6 ? vin.substring(vin.length - 6) : "未知"}')
      ..writeln('【快照条数】${asc.length} 条（同一车况已自动去重，只保留首尾）')
      ..writeln('【区间】${_fmtDt(first.capturedAtDt)} → ${_fmtDt(last.capturedAtDt)}')
      ..writeln('【时长】${_humanSpan(last.capturedAtDt.difference(first.capturedAtDt))}')
      ..writeln()
      ..writeln('## 关键变化')
      ..writeln(_line('油量', '${first.fuelPercent}% → ${last.fuelPercent}%',
          fuelDelta == null ? null : '${fuelDelta >= 0 ? '+' : ''}$fuelDelta 个百分点'))
      ..writeln(_line('综合续航', '${first.rangeKm} km → ${last.rangeKm} km',
          rangeDelta == null ? null : '${rangeDelta >= 0 ? '+' : ''}$rangeDelta km'))
      ..writeln(_line(
          '总里程',
          '${_f1(first.odometerKm)} km → ${_f1(last.odometerKm)} km',
          driven == null
              ? null
              : '区间行驶约 ${driven.abs().toStringAsFixed(1)} km${driven < 0 ? "（读数为回退，可能是数据异常）" : ""}'))
      ..writeln(_line(
          '车内温度',
          interiorTemps.isEmpty
              ? '无数据'
              : '${_f1(interiorTemps.reduce((a, b) => a < b ? a : b))} ~ ${_f1(interiorTemps.reduce((a, b) => a > b ? a : b))} ℃',
          interiorTemps.isEmpty ? null : '波动 ${_f1(interiorTemps.reduce((a, b) => a > b ? a : b) - interiorTemps.reduce((a, b) => a < b ? a : b))} ℃'))
      ..writeln(_line(
          '车外温度',
          exteriorTemps.isEmpty
              ? '无数据'
              : '${_f1(exteriorTemps.reduce((a, b) => a < b ? a : b))} ~ ${_f1(exteriorTemps.reduce((a, b) => a > b ? a : b))} ℃',
          null))
      ..writeln(_line('停放位置', '监测到 $moves 次位置变化', null))
      ..writeln();

    // 若油量/里程有变化，粗算油耗（有总里程差才有意义）
    if (driven != null && driven.abs() > 1 && fuelDelta != null && fuelDelta < 0) {
      final liters = (-fuelDelta) / 100 * 50;
      final per100 = liters / driven.abs() * 100;
      sb.writeln(
          '## 推算油耗\n基于油量百分比与总里程差粗算：期间耗油约 ${liters.toStringAsFixed(1)} L，'
          '折合约 ${per100.toStringAsFixed(1)} L/100km（仅供参考，受油表精度影响）。\n');
    }

    sb.writeln('## 明细（抽样）');
    sb.writeln('时间 | 油量% | 续航km | 总里程km | 车内℃ | 车外℃ | 位置');
    for (final r in _sample(asc, max: 48)) {
      sb.writeln([
        _fmtDt(r.capturedAtDt),
        r.fuelPercent?.toString() ?? '-',
        r.rangeKm?.toString() ?? '-',
        r.odometerKm?.toStringAsFixed(0) ?? '-',
        r.interiorTemp?.toStringAsFixed(0) ?? '-',
        r.exteriorTemp?.toStringAsFixed(0) ?? '-',
        (r.latitude == null || r.longitude == null)
            ? '-'
            : _shortLoc(r.latitude!, r.longitude!),
      ].join(' | '));
    }
    return sb.toString();
  }

  /// 均匀抽样：始终保留首尾，中间等间隔取，使总数 ≤ max。
  List<SnapshotRow> _sample(List<SnapshotRow> asc, {required int max}) {
    if (asc.length <= max) return asc;
    final out = <SnapshotRow>[asc.first];
    final step = (asc.length - 2) / (max - 2);
    for (var i = 1; i < max - 1; i++) {
      out.add(asc[(i * step).round().clamp(1, asc.length - 2)]);
    }
    out.add(asc.last);
    // 抽样可能产生重复索引，去个重
    final seen = <int>{};
    return out.where((e) => seen.add(e.id)).toList(growable: false);
  }

  String _line(String label, String value, String? change) =>
      '- $label：$value${change == null ? '' : '，$change'}';

  /// 位置缩略：把 WGS-84 转成 GCJ-02 后再显示，和地图页面对齐
  String _shortLoc(String lat, String lng) {
    final la = double.tryParse(lat);
    final ln = double.tryParse(lng);
    if (la == null || ln == null) return '有';
    final g = wgs84ToGcj02(la, ln);
    return '${g.lat.toStringAsFixed(4)},${g.lng.toStringAsFixed(4)}';
  }

  // ── 场景 2：当前车况体检 / 智能解读 ─────────────────────────────────

  /// 场景 2：当前车况体检 / 智能解读。
  ///
  /// [history] 传最近一段时间的快照（时间**倒序**或正序都行，内部会排），
  /// 用来还原"从哪到哪、开了多远、停了多久"这类**行程**信息 ——
  /// 单看一条实时车况是推不出行程的。
  /// [plate] 车牌号（接口不返回，由本机设置提供），只用于报告抬头。
  ///
  /// [previous] 上一次的解读结论。传了它就会以**「对比更新」**的方式分析：
  /// 模型会指出这次相比上次**哪些变了 / 哪些没变 / 上次的提醒是否已缓解**，
  /// 而不是把老结论原样复述一遍。首页「再次分析」走的就是这条路。
  ///
  /// [onDelta] 每收到一段增量文本回调一次 —— 弹层 / 卡片据此边生成边显示，
  /// 缓解"点了按钮十几秒没反应"的体感问题。
  Future<String> diagnose(
    VehicleSummary s, {
    String? vin,
    String? plate,
    List<SnapshotRow>? history,
    String? previous,
    void Function(String soFar)? onDelta,
  }) async {
    final hasPrev = buildPreviousSection(previous).isNotEmpty;
    final prompt = _buildDiagnosePrompt(s,
        vin: vin, plate: plate, history: history, previous: previous);
    return chat(
      [
        {
          'role': 'system',
          'content':
              '你是 2021 款名爵 MG5（1.5L 燃油车）的专属汽车管家兼行车助理。'
              '请根据下面的实时车况与近期行程数据，用简体中文输出一份「车辆体检 + 用车分析」。'
              '只依据给定数据判断，缺失的字段写「无数据」，绝不臆测或编造。'
              '燃油车没有的电动功能（动力电池电量、充电状态、充电桩等）不要提；座椅加热只有在真实状态字段有值时才描述。\n'
              '★ 位置只有 GCJ-02 经纬度、没有地址：'
              '**禁止**编造"某某路/某某小区/公司/家"这类具体地点名，'
              '描述行程时用「起点 → 终点（直线位移 x km）」这种基于数据的方式表述；'
              '确实需要指代时可以说「A 点 / B 点」，并附上坐标。\n'
              '${hasPrev ? '★ 下文附了**上一次的结论**，请做「前后对比」：'
                  '明确指出相比上次**哪些指标发生了变化（数值 + 方向）/ 哪些维持不变**，'
                  '上次提醒过的问题这次是**缓解、恶化还是仍在**；'
                  '结论要与上次形成呼应，但**不要整段复述上一次的内容**。\n' : ''}'
              'Markdown 风格，700 字以内，结构固定为：\n'
              '### 总体状态（一句话结论 + 一到五星健康度）\n'
              '${hasPrev ? '### 相比上次的变化（变了什么、没变什么；上次提醒的项现在如何）\n' : ''}'
              '### 行程与用车场景（从哪到哪、行驶距离、用时、停放时长与规律；'
              '历史数据不足就写「历史数据不足，无法还原行程」）\n'
              '### 需要留意（逐项：现象 → 影响 → 怎么处理；没有就写「暂无」）\n'
              '### 用车建议（2~4 条，具体可执行）',
        },
        {'role': 'user', 'content': prompt},
      ],
      temperature: 0.4,
      // 同 analyzeHistory：压到 1024，避免免费档 max output 400
      maxTokens: 1024,
      onDelta: onDelta,
    );
  }

  String _buildDiagnosePrompt(
    VehicleSummary s, {
    String? vin,
    String? plate,
    List<SnapshotRow>? history,
    String? previous,
  }) {
    final tyres = s.tyreKpa;
    String tyreStr = '无数据';
    if (tyres != null && tyres.isNotEmpty) {
      const names = ['左前', '右前', '左后', '右后'];
      final parts = <String>[];
      for (var i = 0; i < tyres.length && i < 4; i++) {
        parts.add('${names[i]} ${tyres[i] ?? '-'} kPa');
      }
      tyreStr = parts.join(' / ');
    }

    final alerts = s.alerts ?? const [];
    final alertStr = alerts.isEmpty
        ? '无'
        : alerts
            .map((a) =>
                'type=${a.alertType} id=${a.alertId} data=${a.alertData}')
            .join('；');

    final sb = StringBuffer()
      ..writeln('【车辆】2021 款名爵 MG5 · 1.5L 燃油 · 45L 油箱')
      ..writeln('【车牌】${(plate ?? '').trim().isEmpty ? '未填写' : plate!.trim()}')
      ..writeln(
          '【VIN 后 6 位】${vin != null && vin.length >= 6 ? vin.substring(vin.length - 6) : "未知"}')
      ..writeln('【数据更新时间】${_fmtServerTs(s.updateTime)}')
      ..writeln()
      ..writeln('## 一、实时车况')
      // 里程 / 距离类
      ..writeln('- 油量：${s.fuelPercent == null ? '无数据' : '${s.fuelPercent}%'}（油箱 45L，'
          '约合 ${s.fuelPercent == null ? '无数据' : '${(s.fuelPercent! / 100 * 50).toStringAsFixed(1)} L'}）')
      ..writeln('- 综合续航：${s.rangeKm == null ? '无数据' : '${s.rangeKm} km'}')
      ..writeln('- 总里程（里程表）：${s.odometerKm == null ? '无数据' : '${s.odometerKm!.toStringAsFixed(1)} km'}')
      ..writeln('- 本次行程里程：${s.journeyKm == null ? '无数据' : '${s.journeyKm!.toStringAsFixed(1)} km'}')
      ..writeln('- 平均油耗：${s.fuelConsumption == null ? '无数据' : '${s.fuelConsumption!.toStringAsFixed(1)} L/100km'}')
      // 温度类
      ..writeln('- 车内温度：${s.interiorTemp == null ? '无数据' : '${s.interiorTemp!.toStringAsFixed(1)} ℃'}'
          '，车外温度：${s.exteriorTemp == null ? '无数据' : '${s.exteriorTemp!.toStringAsFixed(1)} ℃'}'
          '${_tempHint(s)}')
      // 安全类
      ..writeln('- 四门锁闭：${_yn(s.allLocked)}，四门关闭：${_yn(s.allDoorsClosed)}，'
          '车窗关闭：${_yn(s.allWindowsClosed)}')
      // 胎压
      ..writeln('- 胎压：$tyreStr')
      ..writeln('- 当前位置（GCJ-02）：${_fmtLocGcj(s.latitude, s.longitude)}')
      ..writeln('- 车端告警：$alertStr')
      ..writeln();

    // ── 二、近期行程（从历史快照还原，回答"从哪去哪"） ────────────────
    sb.writeln('## 二、近期行程（由本机历史快照还原）');
    final rows = history ?? const <SnapshotRow>[];
    if (rows.isEmpty) {
      sb.writeln('- 本机暂无历史快照，无法还原行程与位置变化。'
          '（提示：在主页多次下拉刷新即可积累）');
    } else {
      final asc = [...rows]..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      sb.writeln('- 快照区间：${_fmtDt(asc.first.capturedAtDt)} → '
          '${_fmtDt(asc.last.capturedAtDt)}，共 ${asc.length} 条');
      final odoDelta = _diff(asc.first.odometerKm, asc.last.odometerKm);
      final fuelDelta = _diff(asc.first.fuelPercent, asc.last.fuelPercent);
      if (odoDelta != null) {
        sb.writeln('- 里程表变化：${_f1(asc.first.odometerKm)} km → '
            '${_f1(asc.last.odometerKm)} km，期间行驶约 '
            '${odoDelta.abs().toStringAsFixed(1)} km');
      }
      if (fuelDelta != null) {
        final liters = (-fuelDelta) / 100 * 50;
        sb.writeln('- 油量变化：${asc.first.fuelPercent}% → ${asc.last.fuelPercent}%'
            '（${fuelDelta >= 0 ? '+' : ''}$fuelDelta 个百分点'
            '${liters > 0 ? '，约耗油 ${liters.toStringAsFixed(1)} L' : ''}）');
        if (odoDelta != null && odoDelta > 1 && liters > 0) {
          sb.writeln('- 按上式粗算油耗：约 ${(liters / odoDelta * 100).toStringAsFixed(1)} L/100km'
              '（受油表精度影响，仅供参考）');
        }
      }
      sb.writeln('- 行程轨迹（按时间顺序）：');
      sb.write(_buildMovement(asc));
    }
    sb
      ..writeln()
      ..writeln('## 三、判断口径')
      ..writeln('- 油量低于 20% 视为需要尽快加油；低于 10% 为紧急。')
      ..writeln('- 胎压正常范围按 220~250 kPa 判断，低于 200 或高于 270 提示检查。')
      ..writeln('- 冬季/夏季胎压会随气温漂移，温差 10 ℃ 约影响 8~10 kPa。')
      ..writeln('- 四门/车窗任一为「否」即存在安全或淋雨风险。')
      ..writeln('- 车内温度明显高于车外且差值大时，注意暴晒/闷热，别把儿童宠物留在车内。')
      ..writeln('- 位置只有经纬度（GCJ-02），**不要编造地名**；'
          '行程一律用「起点坐标 → 终点坐标（直线位移 x km，历时 y 分钟）」表述。');

    // ── 四、上一次的结论（仅「再次分析」时提供，供模型做对比） ──────────
    final prevSection = buildPreviousSection(previous);
    if (prevSection.isNotEmpty) {
      sb
        ..writeln()
        ..write(prevSection);
    }

    return sb.toString();
  }

  /// 车内/车外温差提示（辅助模型判断暴晒、空调、冷启动等场景）
  String _tempHint(VehicleSummary s) {
    final i = s.interiorTemp;
    final e = s.exteriorTemp;
    if (i == null || e == null) return '';
    final d = i - e;
    if (d >= 8) return '（车内比车外高 ${d.toStringAsFixed(1)} ℃，疑似暴晒）';
    if (d <= -8) return '（车内比车外低 ${d.toStringAsFixed(1)} ℃，疑似开空调）';
    return '（内外温差 ${d.toStringAsFixed(1)} ℃）';
  }

  /// 用历史快照还原"停放点 → 移动到 → 停放点"的行程链。
  ///
  /// 做法：把连续且坐标相同的快照合并成一个「停放点」（坐标取 4 位小数
  /// ≈ 11 m 精度，避免 GPS 抖动把一次停放拆成几十段），
  /// 再在相邻停放点之间算直线位移与历时。
  ///
  /// 注意：只给**直线位移**，不是实际行驶路径长度（没有轨迹采样点，
  /// 无法还原走过的路）。报告里也据此措辞，避免误导。
  String _buildMovement(List<SnapshotRow> asc) {
    final located = asc
        .where((r) =>
            (r.latitude ?? '').isNotEmpty && (r.longitude ?? '').isNotEmpty)
        .toList(growable: false);
    if (located.isEmpty) {
      return '  （历史快照里没有定位数据，无法还原行程）\n';
    }

    String key(SnapshotRow r) {
      final la = double.tryParse(r.latitude ?? '');
      final ln = double.tryParse(r.longitude ?? '');
      if (la == null || ln == null) return '?';
      return '${la.toStringAsFixed(4)},${ln.toStringAsFixed(4)}';
    }

    // 合并连续同位置快照 → 停放点
    final stops = <List<SnapshotRow>>[];
    for (final r in located) {
      if (stops.isNotEmpty && key(stops.last.last) == key(r)) {
        stops.last.add(r);
      } else {
        stops.add([r]);
      }
    }

    // 太多就只保留最近 30 个停放点，避免 prompt 爆炸
    const maxStops = 30;
    final truncated = stops.length > maxStops;
    final view = truncated ? stops.sublist(stops.length - maxStops) : stops;

    final sb = StringBuffer();
    SnapshotRow? prev;
    for (var i = 0; i < view.length; i++) {
      final group = view[i];
      final from = group.first;
      final to = group.last;
      final stay = to.capturedAtDt.difference(from.capturedAtDt);

      if (prev == null) {
        sb.writeln('  - ${_fmtDt(from.capturedAtDt)} 起停放于 '
            '${_fmtLocGcj(from.latitude, from.longitude)}'
            '（持续 ${_humanSpan(stay)}，到 ${_fmtDt(to.capturedAtDt)}）');
      } else {
        final moved = _haversineKm(
          prev.latitude,
          prev.longitude,
          from.latitude,
          from.longitude,
        );
        final dur = from.capturedAtDt.difference(prev.capturedAtDt);
        final odo = (from.odometerKm != null && prev.odometerKm != null)
            ? from.odometerKm! - prev.odometerKm!
            : null;
        final avgKmh = dur.inMinutes > 0
            ? moved / (dur.inMinutes / 60)
            : null;
        sb.writeln('  - ${_fmtDt(from.capturedAtDt)} 从 '
            '${_fmtLocGcj(prev.latitude, prev.longitude)} 移动到 '
            '${_fmtLocGcj(from.latitude, from.longitude)}'
            '：直线位移 ${moved.toStringAsFixed(1)} km'
            '${odo != null ? '，里程表 +${odo.toStringAsFixed(1)} km' : ''}'
            '，历时 ${_humanSpan(dur)}'
            '${avgKmh != null ? '，平均约 ${avgKmh.toStringAsFixed(0)} km/h' : ''}');
        if (stay.inMinutes >= 5) {
          sb.writeln('    之后在此停放 ${_humanSpan(stay)}（到 ${_fmtDt(to.capturedAtDt)}）');
        }
      }
      prev = to;
    }
    if (truncated) {
      sb.writeln('  - （更早的 ${stops.length - maxStops} 段行程已省略）');
    }
    return sb.toString();
  }

  /// 两点间大圆距离（km）。用的是 WGS-84 原始坐标，两两之间做距离
  /// 不受 GCJ-02 偏移影响（偏移是整体平移，差值近似抵消）。
  static double _haversineKm(String? lat1, String? lng1, String? lat2, String? lng2) {
    final a1 = double.tryParse(lat1 ?? '');
    final o1 = double.tryParse(lng1 ?? '');
    final a2 = double.tryParse(lat2 ?? '');
    final o2 = double.tryParse(lng2 ?? '');
    if (a1 == null || o1 == null || a2 == null || o2 == null) return 0;
    const r = 6371.0088;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(a2 - a1);
    final dLng = rad(o2 - o1);
    final h = (1 - math.cos(dLat)) / 2 +
        math.cos(rad(a1)) * math.cos(rad(a2)) * (1 - math.cos(dLng)) / 2;
    final clamped = h <= 0 ? 0.0 : (h >= 1 ? 1.0 : h);
    return 2 * r * math.asin(math.sqrt(clamped));
  }

  /// WGS-84 → GCJ-02 后格式化（与地图页/历史页口径一致）
  static String _fmtLocGcj(String? lat, String? lng) {
    final la = double.tryParse(lat ?? '');
    final ln = double.tryParse(lng ?? '');
    if (la == null || ln == null) return '无定位';
    final g = wgs84ToGcj02(la, ln);
    return '${g.lat.toStringAsFixed(5)}, ${g.lng.toStringAsFixed(5)}';
  }

  static String _yn(bool? v) => v == null ? '未知' : (v ? '是' : '否');

  // ── 场景 3：服务端私有告警码解读 ────────────────────────────────────

  /// 上汽的 vehicle_alerts 是一套没有公开文档的私有码
  /// （形如 `alert_type / alert_id / alert_data`），
  /// 让大模型结合常见车联网告警语义给出「可能含义 + 处置建议」。
  Future<String> explainAlerts(
    VehicleSummary s, {
    String? vin,
    void Function(String soFar)? onDelta,
  }) async {
    final alerts = s.alerts ?? const [];
    if (alerts.isEmpty) {
      throw AiException('当前没有告警需要解读');
    }
    final body = StringBuffer()
      ..writeln('【车型】2021 款名爵 MG5 · 1.5L 燃油')
      ..writeln(
          '【VIN 后 6 位】${vin != null && vin.length >= 6 ? vin.substring(vin.length - 6) : "未知"}')
      ..writeln('【告警条数】${alerts.length}')
      ..writeln()
      ..writeln('## 原始告警')
      ..writeln('alert_type | alert_id | alert_data | alert_time');
    for (final a in alerts) {
      body.writeln('${a.alertType} | ${a.alertId} | ${a.alertData} | '
          '${_fmtServerTs(a.alertTime)}');
    }
    body
      ..writeln()
      ..writeln('## 同车其他状态（辅助判断）')
      ..writeln('- 四门锁闭：${_yn(s.allLocked)}，四门关闭：${_yn(s.allDoorsClosed)}，'
          '车窗关闭：${_yn(s.allWindowsClosed)}')
      ..writeln('- 油量：${s.fuelPercent == null ? "无数据" : "${s.fuelPercent}%"}，'
          '续航：${s.rangeKm == null ? "无数据" : "${s.rangeKm} km"}')
      ..writeln('- 车内温度：${s.interiorTemp?.toStringAsFixed(1) ?? "无数据"} ℃，'
          '车外温度：${s.exteriorTemp?.toStringAsFixed(1) ?? "无数据"} ℃');

    return chat(
      [
        {
          'role': 'system',
          'content':
              '你是上汽车联网（SAIC / 斑马智行）系统的资深诊断工程师。'
              '下面给出的是车辆上报的原始告警码，字段没有公开对照表。'
              '请依据车联网告警的常见编码规律（低位通常是具体子项、'
              'data 常为阈值或状态位）与同车其他状态，给出**有依据的推测**，'
              '并明确标注哪些是推测、哪些不确定。用简体中文，Markdown 风格，400 字以内，结构：\n'
              '### 逐条解读（每条：可能含义 → 依据 → 置信度 高/中/低）\n'
              '### 优先级排序（先处理哪条）\n'
              '### 处置建议（可执行，1~3 条）\n'
              '如果判断是服务端未清除的历史残留告警，请直接说明并建议忽略。',
        },
        {'role': 'user', 'content': body.toString()},
      ],
      temperature: 0.3,
      maxTokens: 1024,
      onDelta: onDelta,
    );
  }

  // ── 小工具 ──────────────────────────────────────────────────────────

  static String _f1(double? v) => v == null ? '-' : v.toStringAsFixed(1);

  /// 两点差值（任一为空返回 null），用于"首→尾"的变化量
  static num? _diff(num? a, num? b) => (a == null || b == null) ? null : (b - a);

  static String _fmtDt(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  /// 服务端时间戳（毫秒/秒自适应，与 home_page._parseServerTs 口径一致）
  static String _fmtServerTs(int? ts) {
    if (ts == null || ts <= 0) return '未知';
    final ms = ts > 100000000000 ? ts : ts * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _humanSpan(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    if (d.inHours < 24) return '${d.inHours} 小时';
    final days = d.inDays;
    final hours = d.inHours - days * 24;
    return hours == 0 ? '$days 天' : '$days 天 $hours 小时';
  }
}
