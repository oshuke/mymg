// AI 分析结果的展示组件（Day 7 / Day 7+）
//
// 两种用法：
//   1) showAiReport(...)  —— 底部弹层，可自动跑模型，也能只读展示已有结论；
//   2) AiMarkdownText     —— 轻量 Markdown 渲染组件，首页卡片直接内嵌复用。
//
// 通用能力：
//   - 边生成边显示（流式 onDelta）—— 缓解"点了按钮十几秒没反应"的体感问题；
//   - 轻量 Markdown 渲染（标题 / 圆点列表 / 有序列表 / **加粗**，零依赖）；
//   - 复制全文 / 重新分析 / 关闭。

import 'package:flutter/material.dart';
import 'theme_controller.dart';
import 'package:flutter/services.dart';

import 'ai_service.dart';

/// 弹出 AI 分析弹层。
///
/// [run] 为 null 时进入**只读模式**（直接展示 [initialText]）——
/// 首页「查看全文」就是这么用的，不会白跑一次模型。
/// [run] 非 null 时打开即自动执行，[onDelta] 会被透传进去做打字机效果。
Future<void> showAiReport(
  BuildContext context, {
  required String title,
  Future<String> Function(void Function(String soFar) onDelta)? run,
  String? initialText,
  VoidCallback? onOpenSettings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AiReportSheet(
      title: title,
      run: run,
      initialText: initialText,
      onOpenSettings: onOpenSettings,
    ),
  );
}

class AiReportSheet extends StatefulWidget {
  const AiReportSheet({
    super.key,
    required this.title,
    this.run,
    this.initialText,
    this.onOpenSettings,
  });

  final String title;

  /// 跑一次分析。为 null 表示只读展示 [initialText]。
  final Future<String> Function(void Function(String soFar) onDelta)? run;

  /// 打开即展示的文本（上次结论 / 只读内容）。有 [run] 时作为"先看到的旧内容"。
  final String? initialText;

  final VoidCallback? onOpenSettings;

  @override
  State<AiReportSheet> createState() => _AiReportSheetState();
}

class _AiReportSheetState extends State<AiReportSheet> {
  String? _text;
  String? _error;
  bool _loading = false;

  /// 流式过程中已生成的部分（边收边显示）
  String _stream = '';

  @override
  void initState() {
    super.initState();
    _text = widget.initialText;
    // 有 run 才自动跑；只读模式不动。
    if (widget.run != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Future<void> _run() async {
    final run = widget.run;
    if (run == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _stream = '';
    });
    try {
      final r = await run((soFar) {
        if (!mounted) return;
        setState(() => _stream = soFar);
      });
      if (!mounted) return;
      setState(() {
        _text = r;
        _stream = '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is AiException ? e.message : e.toString();
        _stream = '';
        _loading = false;
      });
    }
  }

  void _copy() {
    final t = _text;
    if (t == null) return;
    Clipboard.setData(ClipboardData(text: t));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制分析结果')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: h * 0.86),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 抓手
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).dividerColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 20, color: Color(0xFF7B4DFF)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_text != null && _text!.isNotEmpty)
                  IconButton(
                    tooltip: '复制',
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                    onPressed: _copy,
                  ),
                if (widget.run != null)
                  IconButton(
                    tooltip: '重新分析',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _loading ? null : _run,
                  ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    // 流式进行中：已有内容就边滚边显示，没有才转圈
    if (_loading) {
      if (_stream.trim().isNotEmpty) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StreamingHint(running: true),
              SizedBox(height: 10),
              SelectableText.rich(
                TextSpan(children: buildAiMarkdownSpans(_stream, fallbackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFFF5F5F7) : const Color(0xFF1A1A1E))),
                style: const TextStyle(fontSize: 14.5, height: 1.62),
              ),
            ],
          ),
        );
      }
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 56),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在调用大模型分析…', style: TextStyle(color: AppPalette.muted)),
            SizedBox(height: 6),
            Text('首次响应通常需要 5~20 秒',
                style: TextStyle(color: AppPalette.subtle, fontSize: 12)),
          ],
        ),
      );
    }
    if (_error != null) {
      final isConfig = _error!.contains('未配置');
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.error_outline, size: 44, color: Colors.orange),
            SizedBox(height: 12),
            SelectableText(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.5),
            ),
            SizedBox(height: 16),
            if (isConfig && widget.onOpenSettings != null) ...[
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onOpenSettings!.call();
                },
                icon: Icon(Icons.settings_outlined, size: 18),
                label: Text('去设置 AI'),
              ),
              SizedBox(height: 8),
            ],
            if (widget.run != null)
              OutlinedButton(onPressed: _run, child: Text('重试')),
          ],
        ),
      );
    }
    if (_text == null || _text!.trim().isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text('暂无可展示的内容',
              style: TextStyle(color: AppPalette.muted)),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: SelectableText.rich(
        TextSpan(children: buildAiMarkdownSpans(_text!, fallbackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFFF5F5F7) : const Color(0xFF1A1A1E))),
        style: const TextStyle(fontSize: 14.5, height: 1.62),
      ),
    );
  }
}

/// 流式生成中的小提示条（一个转圈 + 文案）
class _StreamingHint extends StatelessWidget {
  const _StreamingHint({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: const Color(0xFF7B4DFF).withValues(alpha: 0.9),
          ),
        ),
        SizedBox(width: 8),
        Text(
          running ? '正在生成…' : '已完成',
          style: TextStyle(fontSize: 12, color: AppPalette.subtle),
        ),
      ],
    );
  }
}

/// 只读的 AI 报告正文（首页卡片内嵌用）。零依赖轻量 Markdown 渲染。
class AiMarkdownText extends StatelessWidget {
  const AiMarkdownText(
    this.text, {
    super.key,
    this.fontSize = 14,
    this.height = 1.6,
    this.color,
  });

  final String text;
  final double fontSize;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFF5F5F7) : const Color(0xFF1A1A1E);
    final sub = dark ? const Color(0xFFB0B0B8) : const Color(0xFF5C5C5C);
    return SelectableText.rich(
      TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          height: height,
          color: color ?? fg,
        ),
        children: buildAiMarkdownSpans(text, fallbackColor: fg, mutedColor: sub),
      ),
      style: TextStyle(fontSize: fontSize, height: height, color: color ?? fg),
    );
  }
}

/// 极简 Markdown → TextSpan：
/// `### 标题`、`- / * 列表`、`1. 有序列表`、`**加粗**`，其余按普通段落。
/// 够用且零依赖。弹层与首页卡片共用（原来是弹层的私有方法，Day 7+ 提出来复用）。
List<InlineSpan> buildAiMarkdownSpans(
  String src, {
  Color? fallbackColor,
  Color? mutedColor,
}) {
  final fg = fallbackColor ?? AppPalette.strong;
  final muted = mutedColor ?? AppPalette.track;
  final spans = <InlineSpan>[];
  for (final raw in src.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      spans.add(const TextSpan(text: '\n'));
      continue;
    }
    // 标题
    final hMatch = RegExp(r'^(#{1,6})\s*(.*)$').firstMatch(line);
    if (hMatch != null) {
      final level = hMatch.group(1)!.length;
      final text = hMatch.group(2)!;
      spans.add(TextSpan(
        children: [
          ..._inlineMarkdown(text, bold: true, baseColor: fg),
          const TextSpan(text: '\n'),
        ],
        style: TextStyle(
          fontSize: level <= 2 ? 16.5 : 15.2,
          fontWeight: FontWeight.w700,
          height: 1.9,
          color: fg,
        ),
      ));
      continue;
    }
    // 分隔线
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(line.trim())) {
      spans.add(TextSpan(text: '────────────\n',
          style: TextStyle(color: muted)));
      continue;
    }
    // 列表
    final bullet = RegExp(r'^\s*[-*+]\s+(.*)$').firstMatch(line);
    if (bullet != null) {
      spans.add(TextSpan(text: '  •  ', style: TextStyle(color: fg)));
      spans.addAll(_inlineMarkdown(bullet.group(1)!, baseColor: fg));
      spans.add(const TextSpan(text: '\n'));
      continue;
    }
    // 有序列表
    final ordered = RegExp(r'^\s*(\d+)[.)]\s+(.*)$').firstMatch(line);
    if (ordered != null) {
      spans.add(TextSpan(
          text: '  ${ordered.group(1)}.  ',
          style: TextStyle(color: fg)));
      spans.addAll(_inlineMarkdown(ordered.group(2)!, baseColor: fg));
      spans.add(const TextSpan(text: '\n'));
      continue;
    }
    spans.addAll(_inlineMarkdown(line, baseColor: fg));
    spans.add(const TextSpan(text: '\n'));
  }
  return spans;
}

List<InlineSpan> _inlineMarkdown(String s,
    {bool bold = false, Color? baseColor}) {
  final out = <InlineSpan>[];
  final c = baseColor ?? AppPalette.strong;
  final base = TextStyle(
    color: c,
    fontWeight: bold ? FontWeight.w700 : null,
  );
  final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
  var idx = 0;
  for (final m in re.allMatches(s)) {
    if (m.start > idx) {
      out.add(TextSpan(
          text: s.substring(idx, m.start),
          style: bold
              ? TextStyle(fontWeight: FontWeight.w700, color: c)
              : base));
    }
    if (m.group(1) != null) {
      out.add(TextSpan(
        text: m.group(1),
        style: TextStyle(fontWeight: FontWeight.w700, color: c),
      ));
    } else {
      out.add(TextSpan(
        text: m.group(2),
        style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: AppPalette.info),
      ));
    }
    idx = m.end;
  }
  if (idx < s.length) {
    out.add(TextSpan(
        text: s.substring(idx),
        style: bold
            ? TextStyle(fontWeight: FontWeight.w700, color: c)
            : base));
  }
  if (out.isEmpty) {
    out.add(TextSpan(text: s, style: TextStyle(color: c)));
  }
  return out;
}
