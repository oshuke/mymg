import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'legal_documents.dart';
import 'settings_components.dart';
import 'ui/glass_surface.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<String> _version = _loadVersion();

  Future<String> _loadVersion() async {
    try {
      final info = await const MethodChannel('mymg/app_info')
          .invokeMapMethod<String, dynamic>('getVersion');
      if (info?['versionName'] != null) {
        return '${info!['versionName']} (${info['versionCode']})';
      }
    } catch (_) {}
    return '版本信息暂不可用';
  }

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: '关于 MYMG',
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        GlassSurface(
          child: Column(
            children: [
              Icon(
                Icons.directions_car_rounded,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              const Text(
                'MYMG',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const Text('让爱车状态，一目了然'),
              const SizedBox(height: 8),
              FutureBuilder<String>(
                future: _version,
                builder: (_, snapshot) => Text(snapshot.data ?? '读取版本…'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _section(
          '为燃油车而设计',
          '主要适配 2021 款 MG5 燃油车。查看车况、油量、续航、位置与历史，使用远程控车和蓝牙数字钥匙。部分功能取决于车辆配置、账户权限与当前构建，座椅加热目前仅展示状态。',
        ),
        _section(
          '使用前请了解',
          'MYMG 是个人维护的第三方客户端，与上汽、MG、荣威、小米等品牌无隶属或官方合作关系。仅用于本人或明确获得授权的车辆与账户，不提供绕过鉴权的能力或授权。品牌名称与商标归相应权利人所有。',
        ),
        _section(
          '安全与可靠性',
          '请停车后操作，控车前确认周围安全。车况与续航可能延迟或有误差；蓝牙、网络、系统后台限制或服务方变更可能导致功能不可用。请保留实体钥匙等可靠兜底方式，并现场确认车锁、车窗。AI 解读不能替代车辆检查和专业维修。责任限制仅在法律允许范围内适用，不排除法定责任或用户权利。',
        ),
        _section(
          '隐私提醒',
          '账号、车辆标识、位置与历史主要保存在本机；联网功能会将必要数据发送给相应服务方。当前备份可能包含 PIN 与 AI Key，且未做应用层加密。请使用可信存储，分享反馈前遮挡车牌、VIN、手机号、地址及密钥。',
        ),
        GlassSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('用户协议'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openLegalDocument(context, LegalDocument.terms),
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('隐私政策'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openLegalDocument(context, LegalDocument.privacy),
              ),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('开源项目与反馈'),
                subtitle: const Text('github.com/oshuke/mymg · 请勿提交私人信息'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () async {
                  bool opened = false;
                  try {
                    opened = await launchUrl(
                      Uri.parse('https://github.com/oshuke/mymg'),
                      mode: LaunchMode.externalApplication,
                    );
                  } catch (_) {}
                  if (!opened && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('无法打开浏览器，请访问 github.com/oshuke/mymg'),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.favorite_outline),
                title: const Text('开源许可与感谢'),
                subtitle: const Text('查看 Flutter 与应用依赖许可'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'MYMG',
                  applicationLegalese: '公开仓库采用 GPL-3.0；依赖分别遵循各自许可证。',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _section(
          '感谢每一份开源贡献',
          '感谢 Flutter / Dart、Rust、flutter_rust_bridge、flutter_map、SQLite / sqflite、fl_chart、shared_preferences、flutter_secure_storage、Workmanager 及其他依赖的维护者，也感谢测试用户与社区贡献者。地图数据和服务另有许可与署名要求。\n\n公开仓库的范围以 README 与 LICENSE 为准。账号凭据、车辆个人数据和未获再分发授权的第三方材料不属于公开内容；公开源码许可不授予厂商接口、商标或 SDK 的使用与分发权。',
        ),
      ],
    ),
  );

  Widget _section(String title, String content) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: GlassSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(content, style: const TextStyle(fontSize: 13, height: 1.7)),
        ],
      ),
    ),
  );
}
