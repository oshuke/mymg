# MYMG · 第三方车联客户端

> **非官方项目。** 本项目与上汽集团、名爵（MG）无任何关联，未获其授权或认可。
> 仅用于车主对自己**合法拥有**的车辆做数据查看与操作，禁止用于任何商业用途。

一个面向名爵 MG 车型的第三方车联客户端：Flutter 界面 + Rust 核心，自己实现登录、车况读取与远程控车。
图标、首页插画均为自制素材；仓库内**不包含**任何官方 App 的安装包、反编译产物、抓包数据或协议密钥。

---

## 功能

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

本仓库**不包含**任何厂商服务器的域名、接口路径、签名密钥、厂商 UUID 等协议参数。
这些值在源码里全部改为构建期注入（Rust `option_env!` + Dart `String.fromEnvironment`）：

- 未配置时，App **可以编译、可以启动**，但联网功能会直接提示「尚未配置协议参数」
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
2. 如果为了"能用"而把参数打进公开分发的 APK，等于公开分发他人服务端的地址与密钥——
   这既违反本项目"不携带凭据"的原则，也与 GPL-3.0 关于二进制分发必须提供对应源码的要求冲突
   （分发更完整的二进制却只公开脱敏源码，是不成立的）。

所以：**源码 = 二进制**。你需要自己的参数才能构建出可用版本，构建方法见 [docs/BUILD.md](docs/BUILD.md)。

## 架构

Flutter（UI / 状态 / 通知）→ flutter_rust_bridge → Rust（HTTP、鉴权、签名、控车、数据模型）→ 你的接口。
Android 原生侧负责小组件、快捷控车 Activity、前台服务与数字钥匙扩展点。
详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 隐私

本项目不含任何统计/上报代码，所有数据都留在本机；AI 解读与 WebDAV 备份仅在你主动配置后才会外发。
详见 [docs/PRIVACY.md](docs/PRIVACY.md)。

## 合规与免责

- 仅限**你自己拥有或获得明确授权**的车辆使用；不得用于他人车辆。
- 不得用于商业用途、批量控制、绕过官方付费服务。
- 使用本软件可能违反车辆厂商的用户协议；因此导致的服务中断、账号封禁、车辆异常等风险由使用者自行承担。
- 本项目不提供、不索取、不分发任何官方密钥或访问凭据；你需要自行合法获取与自己账号相关的凭据。
- 仓库内不包含官方 App 的二进制、反编译代码、抓包文件或个人车辆数据（VIN、MAC、位置、手机号等）。
- 若权利人认为本项目侵犯其权益，请通过 issue 联系，我们会及时处理。

## 许可证

[GNU General Public License v3.0](LICENSE)（GPL-3.0）。

## 致谢

- [Flutter](https://flutter.dev/)、[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/)
- 所有为本项目提供开源依赖的作者
