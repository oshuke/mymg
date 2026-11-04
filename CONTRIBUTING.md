# 贡献指南

感谢愿意帮忙。这个项目的定位是「车主自己用的第三方客户端」，所以请先理解以下边界。

## 不接受的内容

- ❌ 任何官方 App 的二进制、反编译代码、抓包文件、接口文档
- ❌ 任何密钥、令牌、验证码、证书、厂商 UUID 明文
- ❌ 任何真实车辆数据：VIN、车牌、手机号、T-Box MAC、定位、账号
- ❌ 绕过付费/鉴权、批量控制、他人车辆相关功能
- ❌ 引入统计/埋点 SDK

提交前检查完整暂存区：`git diff --cached --check` 与 `git diff --cached --name-status`。
核对令牌、VIN、车牌、手机号、MAC、精确位置、私有协议常量和素材授权；仅搜索某一种 VIN 前缀不足以排除泄漏。
测试仅使用明确的合成数据；不提交 APK、厂商照片、设计参考图、调试截图、备份包或本地协议配置。

## 可以提

- 车况字段解析的健壮性（缺字段、类型变化）
- UI/交互、无障碍、深色模式
- 本地缓存、历史曲线、告警规则
- 文档修正（错别字、步骤跑不通）
- 性能（启动速度、列表卡顿、内存）

## 开发流程

```bash
# 1. 准备环境（见 docs/BUILD.md），配好 config/protocol.env
# 2. 改代码
flutter analyze            # 必须 0 error
cd rust && cargo test --offline
# 3. 真机验证：UI 改动必须走真实路径跑一遍，不能只看单测
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## 代码约定

- Dart：跟随现有代码风格，优先复用已有组件；不引入新的大型依赖前先开 issue 讨论。
- Rust：`rust/` 里业务代码不得出现硬编码域名/路径/密钥，一律走 `vehicle/protocol.rs`。
- Kotlin：新增 MethodChannel 方法要同时更新 `docs/PROTOCOL.md` 的契约表。
- 提交信息：一句话说清「改了什么、为什么」，中英文均可。

## 提交 PR

1. fork → 建分支 → 改；
2. 跑 `flutter analyze` 与 `cargo test`；
3. PR 描述里写：改了什么、怎么验证的（截图/日志）、是否影响已有配置；
4. 不要在一个 PR 里混重构与功能。

## 许可证

贡献的代码默认以 GPL-3.0 授权（见 [LICENSE](LICENSE)）；请确认拥有代码及素材的公开分发权。
