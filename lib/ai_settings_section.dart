// 设置页「AI 智能分析」：内联展开面板（与其它分类一致的折叠风格）。

import 'package:flutter/material.dart';

import 'ai_service.dart';

/// 折叠项右侧摘要（设置页折叠标题用）
class AiSettingsSummary extends StatelessWidget {
  const AiSettingsSummary({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: AiService.instance.load(),
      builder: (context, snap) => Text(
        (snap.data?.enabled ?? false) ? '已启用' : '未启用',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

/// 展开内容：启用开关 / 服务商预设 / 接口地址 / 模型 / API Key / 测试连接
class AiSettingsSection extends StatefulWidget {
  const AiSettingsSection({super.key});

  @override
  State<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends State<AiSettingsSection>
    with AutomaticKeepAliveClientMixin {
  bool _enabled = true;
  String _savedMasked = '';
  bool _testing = false;
  String? _testOk;
  String? _testErr;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;

  // 内联面板在 ListView 里滚出屏幕后仍保留已填内容
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await AiService.instance.load(force: true);
    final masked = await AiService.instance.maskedKey();
    if (!mounted) return;
    setState(() {
      _enabled = cfg.enabled;
      _urlCtrl.text = cfg.baseUrl;
      _modelCtrl.text = cfg.model;
      _savedMasked = masked;
    });
  }

  Future<void> _save() async {
    await AiService.instance.save(
      baseUrl: _urlCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      enabled: _enabled,
    );
    final masked = await AiService.instance.maskedKey();
    if (!mounted) return;
    setState(() => _savedMasked = masked);
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testOk = null;
      _testErr = null;
    });
    try {
      await _save();
      final r = await AiService.instance.testConnection();
      if (!mounted) return;
      setState(() {
        _testOk = r;
        _testErr = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testErr = e.toString();
        _testOk = null;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickPreset() async {
    final selected = await showModalBottomSheet<AiPreset>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: kAiPresets
              .map((p) => ListTile(
                    title: Text(p.name),
                    subtitle:
                        Text(p.baseUrl, style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, p),
                  ))
              .toList(),
        ),
      ),
    );
    if (selected == null) return;
    await AiService.instance.save(
        baseUrl: selected.baseUrl, model: selected.model);
    final cfg = await AiService.instance.load(force: true);
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = cfg.baseUrl;
      _modelCtrl.text = cfg.model;
    });
  }

  Future<void> _pickApiKey() async {
    final ctrl = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API Key'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: '粘贴 API Key',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (r != null && r.trim().isNotEmpty) {
      await AiService.instance.save(apiKey: r.trim());
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) {
              setState(() => _enabled = v);
              _save();
            },
            title: const Text('启用 AI'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bolt, size: 20),
            title: const Text('服务商预设'),
            subtitle: Text(
              _urlCtrl.text.isEmpty ? '未选择' : _urlCtrl.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _pickPreset,
          ),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: 'https://api.deepseek.com/v1',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-chat',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vpn_key_outlined, size: 20),
            title: const Text('API Key'),
            subtitle: Text(
              _savedMasked.isEmpty ? '未设置' : '已保存 $_savedMasked',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  onPressed: _pickApiKey,
                ),
                if (_savedMasked.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      await AiService.instance.save(apiKey: '');
                      await _load();
                    },
                  ),
              ],
            ),
          ),
          if (_testing)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_testOk != null)
            Text(_testOk!,
                style: const TextStyle(fontSize: 12, color: Colors.green)),
          if (_testErr != null)
            Text(_testErr!,
                style: const TextStyle(fontSize: 12, color: Colors.red)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _testing ? null : _test,
                child: const Text('测试连接'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  await _save();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('AI 配置已保存')),
                    );
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
