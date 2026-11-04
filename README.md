# MYMG · 第三方车联客户端

> **非官方项目。** 本项目与上汽集团、名爵（MG）无任何关联，未获其授权或认可。
> 仅应对自己合法拥有或获得明确授权的车辆进行操作；代码使用和分发遵循 GPL-3.0。

一个面向名爵 MG 车型的第三方车联客户端：Flutter 界面 + Rust 核心，自己实现登录、车况读取与远程控车。
图标、首页插画均为自制素材；仓库内**不包含**任何官方 App 的安装包、反编译产物、抓包数据或协议密钥。

---

## 功能

**界面与导航**

- 浅色磨砂玻璃与蓝色主题，支持深色模式；四个悬浮胶囊入口：首页、车控、车况、位置。
- 设置从首页右上角进入，数字钥匙等功能统一放在设置；历史记录放在首页。
- 子页面返回上一级，其他主页面返回首页；首页两次返回将任务移到后台。
- 车辆图片可在本机替换并恢复默认；开源版使用原有自制插画，不包含厂商车辆照片或设计参考图。
- 面向燃油车，移除充电与 OTA 入口；告警展示具体数据，无法确认的编号明确标注；座椅加热仅显示状态。

**车况**

- 车况总览：油量/续航、里程、胎压、门窗/中控锁状态、温度等（字段按接口响应动态渲染）
- 车辆位置、地图展示（GCJ-02 坐标纠偏）、本次行程
- 历史曲线（油量/里程/胎压趋势，`fl_chart`）
- 本地 SQLite 快照 + 去重，离线可看最后一次数据

**控车**

- 远程控车：锁车 / 解锁 / 后备箱 / 寻车 / 空调 / 车窗（取决于你配置的接口能力）
- 快捷控车页（`QuickControlActivity`）：磁贴、桌面小组件、图标长按共用同一入口

**辅助**

- 本地 + 云端告警规则、通知推送
- AI 车况解读（自填任意 OpenAI 兼容接口）
- WebDAV 备份与恢复（自填地址与凭据）
- 主题跟随系统、深色模式

**数字钥匙（扩展点，非内置实现）**

开源版**不包含**厂商 BLE 数字钥匙协议实现，只保留 Flutter ↔ Android 的 MethodChannel 扩展点：
`MymgBleKeyClient` 是一个桩实现，调用会返回「数字钥匙模块未内置」。
如果你有自己的协议实现，可以替换该文件而无需改动界面层，见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

---

## 重要前提：协议参数需要你自己提供

本仓库不内置车辆服务端域名、接口路径、签名密钥、厂商 UUID 等私有协议参数。
这些值在源码里全部改为构建期注入（Rust `option_env!` + Dart `String.fromEnvironment`）：

- 未配置时，App 可以编译、可以启动；车辆服务调用会提示「尚未配置协议参数」。地图与地址解析另见下文。
- 配置方式见 [config/protocol.example.env](config/protocol.example.env) 与 [docs/PROTOCOL.md](docs/PROTOCOL.md)

```bash
cp config/protocol.example.env config/protocol.env
# 填入你自己的值（config/protocol.env 已被 .gitignore 忽略）
set -a; . config/protocol.env; set +a
flutter build apk --release --target-platform android-arm64
```

---

## 构建

依赖、环境变量、签名说明见 [docs/BUILD.md](docs/BUILD.md)。最短路径：

```bash
# 需要 Flutter 3.2x+、Rust 1.7x+、Android SDK/NDK
rustup target add aarch64-linux-android
flutter pub get
flutter build apk --release --target-platform android-arm64
```

## 不提供预编译 APK（重要）

本仓库**不发布 Release 安装包**，只能自行构建。原因：

1. 协议参数在构建期注入，没有你的配置的二进制**装上也用不了**；
2. 把私人参数打进公开 APK 可能暴露账户、密钥及服务配置，超出本仓库的公开边界；
3. 分发修改后的二进制还需另行履行 GPL 对应源码义务，并确认依赖、素材和服务的使用许可。本仓库未对私人版本提供这种发布审核。

你需要自己的合法配置才能启用对应车辆能力，构建方法见 [docs/BUILD.md](docs/BUILD.md)。

## 架构

Flutter（UI / 状态 / 通知）→ flutter_rust_bridge → Rust（HTTP、鉴权、签名、控车、数据模型）→ 你的接口。
Android 原生侧负责小组件、快捷控车 Activity、前台服务与数字钥匙扩展点。
详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 隐私

登录前须主动确认用户协议和隐私政策；关于页可离线阅读说明并查看开源许可。升级后的已登录用户也需确认新版本说明。穿戴 SDK 与手表联动已移除，手机数字钥匙在公开源码中仍为扩展桩。

本项目未接入作者运营的后端或统计 SDK。车辆接口、AI、WebDAV、地图、地址解析和 DNS 回退可能向对应服务方发送数据。
开源版默认不加载在线地图或解析地址；构建时可配置有授权的 GCJ-02 坐标系 HTTPS XYZ 图源及署名，或显式启用第三方地址解析。不要直接使用 WGS84/标准 OSM 图源，显示坐标已转换为 GCJ-02。
登录令牌目前保存在未加密的应用偏好中；备份包可能包含历史位置、控车 PIN 和 AI Key，且未做应用层加密，请勿公开分享。
详见 [docs/PRIVACY.md](docs/PRIVACY.md)；素材与地图许可边界见 [docs/ASSETS.md](docs/ASSETS.md)。

## 合规与免责

- 仅限**你自己拥有或获得明确授权**的车辆使用；不得用于他人车辆。
- 不得未经授权访问他人账户、车辆或服务；本项目不提供绕过鉴权或付费服务的支持。
- 使用本软件可能违反车辆厂商的用户协议；因此导致的服务中断、账号封禁、车辆异常等风险由使用者自行承担。
- 本项目不提供、不索取、不分发任何官方密钥或访问凭据；你需要自行合法获取与自己账号相关的凭据。
- 仓库内不包含官方 App 的二进制、反编译代码、抓包文件或个人车辆数据（VIN、MAC、位置、手机号等）。
- 若权利人认为本项目侵犯其权益，请通过 issue 联系，我们会及时处理。

## 许可证

[GNU General Public License v3.0](LICENSE)（GPL-3.0）。
不另加“禁止商业用途”限制。GPL 授予的代码权利不代表车辆厂商、地图服务或第三方素材的授权；使用者仍须满足相应服务条款和法律要求。

## 致谢

- [Flutter](https://flutter.dev/)、[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/)
- 所有为本项目提供开源依赖的作者
