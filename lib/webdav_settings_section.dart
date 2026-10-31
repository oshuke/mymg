// 设置页「坚果云 WebDAV 备份」：内联展开面板（与其它分类一致的折叠风格）。

import 'package:flutter/material.dart';
import 'theme_controller.dart';

import 'backup_service.dart';
import 'webdav_client.dart';

/// 折叠项右侧摘要（设置页折叠标题用）
class WebDavSettingsSummary extends StatelessWidget {
  const WebDavSettingsSummary({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: BackupService.instance.loadConfig(),
      builder: (context, snap) => Text(
        (snap.data?.user.isNotEmpty ?? false) ? '已配置' : '未配置',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class WebDavSettingsSection extends StatefulWidget {
  const WebDavSettingsSection({super.key});

  @override
  State<WebDavSettingsSection> createState() => _WebDavSettingsSectionState();
}

class _WebDavSettingsSectionState extends State<WebDavSettingsSection>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _folderCtrl;

  bool _auto = false;
  int _intervalH = 24;
  int _maxCount = 10;
  bool _hasPass = false;
  bool _busy = false;
  String? _status;
  DateTime? _lastBackup;
  String? _lastError;
  List<BackupEntry> _remote = const [];
  bool _listLoading = false;

  // 内联面板滚出屏幕后仍保留已填内容
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController();
    _userCtrl = TextEditingController();
    _passCtrl = TextEditingController();
    _folderCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _folderCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await BackupService.instance.loadConfig();
    final auto = await BackupService.instance.autoEnabled;
    final intervalH = await BackupService.instance.intervalHours;
    final maxCount = await BackupService.instance.maxCount;
    final last = await BackupService.instance.lastBackupAt;
    final err = await BackupService.instance.lastError;
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = cfg.url;
      _userCtrl.text = cfg.user;
      _folderCtrl.text = cfg.folder;
      _hasPass = cfg.password.isNotEmpty;
      _auto = auto;
      _intervalH = intervalH;
      _maxCount = maxCount;
      _lastBackup = last;
      _lastError = err;
    });
  }

  Future<void> _saveConfig() async {
    await BackupService.instance.saveConfig(
      url: _urlCtrl.text.trim(),
      user: _userCtrl.text.trim(),
      folder: _folderCtrl.text.trim(),
      password: _passCtrl.text.trim().isEmpty ? null : _passCtrl.text.trim(),
    );
    _passCtrl.clear();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = '正在连接…';
    });
    await _saveConfig();
    try {
      await BackupService.instance.testConnection();
      if (!mounted) return;
      setState(() => _status = '连接成功');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupNow() async {
    setState(() {
      _busy = true;
      _status = '正在备份…';
    });
    await _saveConfig();
    try {
      final name = await BackupService.instance.backupNow();
      if (!mounted) return;
      setState(() => _status = '已备份 $name');
      await _load();
      await _refreshRemote();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '备份失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshRemote() async {
    await _saveConfig();
    setState(() => _listLoading = true);
    try {
      final list = await BackupService.instance.listRemote();
      if (!mounted) return;
      setState(() => _remote = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '列出远程失败：$e');
    } finally {
      if (mounted) setState(() => _listLoading = false);
    }
  }

  Future<void> _restore(BackupEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复备份？'),
        content: Text('将用「${e.name}」覆盖本机快照与设置（保留登录态）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _status = '正在恢复…';
    });
    try {
      await BackupService.instance.restoreRemote(e.name);
      if (!mounted) return;
      setState(() => _status = '已恢复：${e.name}');
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = '恢复失败：$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
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
            value: _auto,
            onChanged: _busy
                ? null
                : (v) {
                    setState(() => _auto = v);
                    BackupService.instance.setAutoEnabled(v);
                  },
            title: const Text('自动备份'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule, size: 20),
            title: const Text('备份周期'),
            subtitle: Text(
                _intervalH < 24 ? '每 $_intervalH 小时' : '每 ${_intervalH ~/ 24} 天'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () async {
              final v = await showModalBottomSheet<int>(
                context: context,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final h in kBackupIntervalOptions)
                        ListTile(
                          title: Text(h < 24 ? '每 $h 小时' : '每 ${h ~/ 24} 天'),
                          trailing: _intervalH == h ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(ctx, h),
                        ),
                    ],
                  ),
                ),
              );
              if (v != null) {
                setState(() => _intervalH = v);
                await BackupService.instance.setIntervalHours(v);
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined, size: 20),
            title: const Text('最大备份数'),
            subtitle: Text('保留 $_maxCount 份'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () async {
              final v = await showModalBottomSheet<int>(
                context: context,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final n in kBackupMaxOptions)
                        ListTile(
                          title: Text('$n 份'),
                          trailing: _maxCount == n ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(ctx, n),
                        ),
                    ],
                  ),
                ),
              );
              if (v != null) {
                setState(() => _maxCount = v);
                await BackupService.instance.setMaxCount(v);
              }
            },
          ),
          const Divider(height: 16),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: WebDavClient.jianguoyunUrl,
              border: OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(
              labelText: '账号',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '应用密码',
              hintText: _hasPass ? '已保存（留空不修改）' : '坚果云应用密码',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _folderCtrl,
            decoration: const InputDecoration(
              labelText: '远程目录',
              hintText: '/MYMG/',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_lastBackup != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '上次备份：${_fmt(_lastBackup!)}',
                style: TextStyle(fontSize: 12, color: AppPalette.muted),
              ),
            ),
          if (_lastError != null && _lastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_lastError!,
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_status!, style: const TextStyle(fontSize: 12)),
            ),
          if (_listLoading)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_remote.isNotEmpty) ...[
            const Divider(height: 16),
            Text('云端备份（${_remote.length}）',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ..._remote.take(10).map((e) {
              final t = BackupService.parseNameTime(e.name);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, size: 18),
                title: Text(t == null ? e.name : _fmt(t),
                    maxLines: 1, style: const TextStyle(fontSize: 13)),
                subtitle: Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11)),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _restore(e),
                  child: const Text('恢复'),
                ),
              );
            }),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : _test,
                child: const Text('测试'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _refreshRemote,
                child: const Text('刷新列表'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _backupNow,
                child: const Text('立即备份'),
              ),
              FilledButton(
                onPressed: () async {
                  await _saveConfig();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('备份配置已保存')),
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
