import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_components.dart';

const legalRevision = '2026-11-04.1';

class LegalConsent {
  static const revisionKey = 'mymg.legal.revision';
  static const acceptedAtKey = 'mymg.legal.accepted_at';

  static Future<bool> isAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(revisionKey) == legalRevision &&
        (prefs.getInt(acceptedAtKey) ?? 0) > 0;
  }

  static Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setInt(
          acceptedAtKey,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ) ||
        !await prefs.setString(revisionKey, legalRevision)) {
      throw StateError('无法保存协议确认，请重试');
    }
  }
}

enum LegalDocument { terms, privacy }

const _terms = '''MYMG 用户协议
版本：2026-11-04.1

1. 项目与使用资格
MYMG 是个人维护的第三方车联客户端，主要适配 2021 款 MG5 燃油车，与上汽、MG、荣威、小米及其他服务商无隶属、授权背书或官方合作关系。商标与品牌名称属于各权利人。仅可操作本人拥有或已取得明确合法授权的车辆与账户，不得获取、传播他人凭据或绕过服务方鉴权。

2. 功能边界与行车安全
车况可能延迟、缺失或错误，续航与油量为估算，不能替代仪表、车辆检查或维修诊断。蓝牙钥匙依赖系统权限、有效钥匙材料、车辆支持与无线环境；远程服务可能因网络、账号或服务端变更不可用。请停车后操作，控车前确认周围安全，随身携带实体钥匙或准备其他可靠方案。未收到明确成功反馈时，请现场确认车锁与车窗。座椅加热当前仅展示状态。

3. 凭据、服务与用户选择
请只输入有权使用的账户凭据。登录、验证码、地图、AI、备份等由相应第三方提供，需遵守其服务条款与授权范围；本项目不能授予第三方服务或 SDK 的使用及再分发许可。AI 输出仅供参考，不作为安全或维修决定的唯一依据。通知、蓝牙等系统权限分别授权，勾选本协议不等于授予所有权限。

4. 源码与分发
公开仓库以其 LICENSE 及各文件/依赖许可为准。第三方组件、商标、照片、私有配置及未公开实现不因公开界面代码自动获得再分发授权。请勿上传私人配置、厂商密钥、日志或含个人信息的 APK。发布二进制时应核对对应源码义务和每个第三方组件的授权，免责声明不能代替授权。

5. 风险与责任
请自行评估测试性软件的适用性，项目不承诺所有车型、系统或服务持续可用。许可文件中的保证与责任限制仅在适用法律允许的范围内适用，不排除法律规定不得排除的责任，也不限制用户依法享有的权利。

6. 更新、停止与联系
协议或数据处理范围发生实质变化时会重新请求确认。可停止使用、撤销系统权限，并在设置中关闭后台功能、退出账户或清理本机数据。远端账户和备份需向相应服务方撤销或删除。问题与隐私请求可通过关于页的 GitHub 项目联系维护者；请勿在公开 Issue 中填写个人信息。
''';

const _privacy = '''MYMG 隐私政策
版本：2026-11-04.1

1. 处理范围
项目未接入作者运营的账号后端、广告或统计 SDK。联网功能仍会向相应第三方发送数据。本说明描述当前客户端；具体构建是否配置车辆服务、地图和数字钥匙实现会影响可用功能与数据去向。

2. 本机数据与保护
登录令牌、VIN、手机号、用户/设备标识与车辆配置保存在应用私有 SharedPreferences，未做应用层加密。控车 PIN、AI API Key、WebDAV 密码使用 flutter_secure_storage，在 Android 通过 KeyStore 保护。车况快照、时间、位置历史、AI 消息及解读保存在应用私有数据库/文件，未统一加密。自选车辆照片会复制到应用私有目录，恢复默认仅删除应用内副本。数字钥匙构建可能在应用私有偏好中保存蓝牙地址、钥匙引用和密钥材料，未统一采用硬件级加密。应用沙箱不等于额外加密；root、系统备份、迁移和日志导出可能改变访问范围。

3. 网络数据去向
登录、车况、控车及后台刷新向构建配置的车辆服务发送令牌、VIN、手机号、账号/设备标识与请求内容。验证码服务处理验证码交互及必要网络/设备信息。在线地图服务收到 IP、瓦片编号与缩放等级，可推断查看区域；完整个人构建可能使用高德图源，公开源码要求自行配置有效图源与署名。地址解析启用时，BigDataCloud、Nominatim/OpenStreetMap 可能收到车辆坐标与 IP；不同构建开关不同。DNS 回退可能使用阿里 DNS-over-HTTPS、DNSPod HTTPS，解析方可看到域名与 IP。打开外部导航会将车辆坐标和目的地传给所选地图应用/网页。

启用 AI 时，所配置的模型服务接收提示词中的车况、时间、历史、位置和消息，API Key 用于认证；自动分析可能在后台发送。WebDAV 服务接收备份与认证信息，自动备份可能自动上传。第三方通常还能看到请求时间、User-Agent 与 IP；其处理规则适用对应服务的政策。请仅配置可信服务，不需要时关闭自动分析和自动备份。在线地址解析由构建配置决定，目前没有应用内关闭开关；公开默认构建关闭该功能。如不接受向解析服务发送坐标，请使用禁用解析的构建或停止使用相关联网功能。

4. 敏感备份与日志
现有备份除数据库、位置历史和账户/车辆配置外，还可能将控车 PIN 与 AI API Key 从安全存储导出；备份包未做应用层加密，压缩不等于加密。WebDAV 密码不包含在备份内。请只备份到自己可信、访问受控的 HTTPS 存储，不公开分享文件或链接。诊断日志可能含接口响应、位置、标识和错误上下文，反馈前请打码。

5. 系统权限与选择
蓝牙扫描/连接用于寻找和连接数字钥匙；当前扫描实现同时请求定位权限，部分设备还要求开启系统定位。蓝牙权限在进入已启用的数字钥匙功能或发起相关操作时申请。通知权限可能在确认协议后的首次进入或应用启动时申请，用于车况、控车结果、预约与前台服务。可拒绝或到系统设置撤销。前台服务、唤醒锁、开机广播和闹钟用于已启用的后台任务。生物识别只进行本机身份验证，本应用不读取指纹或人脸模板。照片选择通过系统选择器，不向作者上传照片。悬浮层为可选快捷控车入口。拒绝可选权限不影响阅读协议和其他不依赖该权限的功能。

6. 保留、删除与撤回
数据通常保留在本机，直到用户清理、退出或卸载；退出登录不等于删除历史、日志和备份。可在设置清理快照，恢复默认图片，关闭后台/AI/备份；完整清除本机数据可通过 Android 应用存储设置。卸载不会删除自行导出的文件、远端备份或第三方留存数据，需另行处理。凭据泄漏请及时向对应服务方撤销/轮换。可停止使用并撤销系统权限；修改数据范围后会要求确认新版本。

7. 联系与政策更新
关于页提供 GitHub 项目入口，可用于联系维护者并提出查询、更正、删除或隐私问题；公开 Issue 不适合传送手机号、VIN、精确位置、密钥或日志。确认仅在本机记录协议版本及 UTC 时间，不上传到作者服务。本说明不替代第三方政策或法定权利。
''';

void openLegalDocument(BuildContext context, LegalDocument document) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LegalDocumentPage(document: document),
    ),
  );
}

class LegalDocumentPage extends StatelessWidget {
  const LegalDocumentPage({super.key, required this.document});
  final LegalDocument document;

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: document == LegalDocument.terms ? '用户协议' : '隐私政策',
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
      child: SelectableText(
        document == LegalDocument.terms ? _terms : _privacy,
        style: const TextStyle(fontSize: 14, height: 1.8),
      ),
    ),
  );
}

class AgreementControl extends StatelessWidget {
  const AgreementControl({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Checkbox(
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
        semanticLabel: '我已阅读并同意用户协议和隐私政策',
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('我已阅读并同意'),
              InkWell(
                onTap: () => openLegalDocument(context, LegalDocument.terms),
                child: Text(
                  '用户协议',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              const Text('和'),
              InkWell(
                onTap: () => openLegalDocument(context, LegalDocument.privacy),
                child: Text(
                  '隐私政策',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Builds vehicle UI only after this installation has confirmed the current text.
class ConsentGate extends StatefulWidget {
  const ConsentGate({super.key, required this.builder, this.onAccepted});
  final WidgetBuilder builder;
  final Future<void> Function()? onAccepted;
  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  late final Future<bool> _accepted = LegalConsent.isAccepted();
  bool _confirmed = false;
  bool _checked = false;
  bool _saving = false;
  String? _error;
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _accepted,
    builder: (context, snapshot) {
      if (_confirmed || snapshot.data == true) return widget.builder(context);
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return SettingsPageFrame(
        title: '使用前请确认',
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.shield_outlined, size: 56),
            const SizedBox(height: 24),
            const Text(
              '欢迎使用 MYMG',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            const Text(
              '这是一款第三方车联客户端。请阅读更新的协议与隐私说明，了解车辆控制风险、账号与位置数据的使用方式。确认前不会进入车辆功能。',
            ),
            const SizedBox(height: 16),
            AgreementControl(
              value: _checked,
              onChanged: _saving ? null : (v) => setState(() => _checked = v),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: !_checked || _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      try {
                        await LegalConsent.accept();
                        await widget.onAccepted?.call();
                        if (mounted) setState(() => _confirmed = true);
                      } catch (_) {
                        if (mounted) setState(() => _error = '无法保存确认，请重试');
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
              child: Text(_saving ? '保存中…' : '同意并继续'),
            ),
            const SizedBox(height: 12),
            const Text(
              '不同意可返回或关闭应用。阅读文档不会自动勾选。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    },
  );
}
