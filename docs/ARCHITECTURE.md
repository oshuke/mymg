# 架构说明

## 分层

```
┌──────────────────────────────────────────────────────────────┐
│ Flutter（lib/）                                              │
│  · 页面与组件：home / history / map / control / settings      │
│  · 状态与缓存：store.dart、summary_cache.dart、vehicle_profile │
│  · 通知与后台：notification_service.dart、background.dart     │
│  · 原生桥：ble_key_bridge.dart、widget_sync.dart              │
└───────────────┬──────────────────────────┬───────────────────┘
                │ flutter_rust_bridge 2.13 │ MethodChannel (mymg/*)
┌───────────────▼──────────────────┐  ┌────▼──────────────────────┐
│ Rust 核心（rust/src/）           │  │ Android 原生（kotlin/）    │
│  · api.rs      暴露给 Dart 的入口│  │  · MainActivity（通道注册）│
│  · vehicle/client.rs  HTTP 请求  │  │  · QuickControlActivity    │
│  · vehicle/auth.rs    登录/令牌  │  │  · MymgWidgetProvider      │
│  · vehicle/signutil.rs 请求签名  │  │  · MymgControlTileService  │
│  · vehicle/control.rs 控车链路   │  │  · MymgBleService（前台）  │
│  · vehicle/model.rs   数据模型   │  │  · MymgBleKeyClient（扩展点）│
│  · vehicle/summary.rs UI 摘要     │  │  · MymgBleScanner（扫描）  │
│  · vehicle/protocol.rs 协议配置  │  │  · CaptchaActivity         │
└──────────────────────────────────┘  └────────────────────────────┘
```

Rust 通过 `rust_builder/`（cargokit，path 依赖）参与 Android 构建，产物是 `libmymg_core.so`；
Dart 侧绑定由 flutter_rust_bridge 生成在 `lib/src/rust/`。

## 数据流（车况）

1. `HomePage` 定时/手动触发 → `lib/src/rust/api.dart` 的 `fetchSummary()`
2. Rust：`api::fetch_summary` → `vehicle::client::MgClient`（reqwest + rustls）
   → 拼 URL（`vehicle/protocol.rs`）→ 签名（`signutil`）→ 请求 → `model.rs` 反序列化
3. `vehicle/summary.rs` 把原始响应压成 UI 摘要 → 经 FRB 返回 Dart
4. Dart 落库（`store.dart`，SQLite）+ 去重（`summary_cache.dart`），再驱动 UI 与告警规则

## 数据流（远程控车）

```
randomCodeWithToken → checkPINCode → 指令接口 → 轮询结果
```

`vehicle/control.rs` 全流程实现；PIN 用四级 SHA1 处理，入参含 PIN、userId、VIN、手机号、验证码等，
因此**身份字段缺失或令牌失效都会被服务端伪装成「PIN 错误」**——排查时先确认令牌与 VIN。

## Android 原生组件

| 组件 | 作用 |
|---|---|
| `MainActivity` | 注册所有 MethodChannel（`mymg/ble`、`mymg/widget`、`mymg/shortcut` 等），承载 Flutter |
| `QuickControlActivity` | 磁贴 / 小组件 / 图标长按共用的透明快捷控车页，含独立 FlutterEngine |
| `MymgWidgetProvider` | 桌面小组件（RemoteViews 布局 `res/layout/mymg_widget_home.xml`） |
| `MymgControlTileService` | 控制中心磁贴 |
| `MymgBleService` | 前台服务（`connectedDevice`），避免进程被冻结导致链路断开 |
| `MymgBleKeyClient` | **数字钥匙扩展点**：开源版为桩实现，替换它即可接入自己的协议 |
| `MymgBleScanner` | BLE 扫描（同样只保留框架） |
| `CaptchaActivity` | 滑块验证码 WebView 壳页（`assets/captcha.html`） |

> 注意：快捷控车页会启动**第二个 FlutterEngine**。原生向 Dart 发事件时必须广播给所有引擎
> （代码里用 `Collections.synchronizedList` 保存多个 MethodChannel），否则主界面收不到事件。

## 存储

| 内容 | 位置 |
|---|---|
| 令牌 / PIN | `flutter_secure_storage`（`pin_vault.dart` 加密后存储） |
| 普通配置 | `shared_preferences` |
| 车况快照 | SQLite（`store.dart`） |
| 车辆图片 | 应用私有目录（`car_image_store.dart`） |

## 关键设计约定

- **协议参数全部来自 `vehicle/protocol.rs`**，任何业务代码不得再出现硬编码域名/路径/密钥。
- 未配置时：`MgClient::new / AuthClient::new / ControlClient::new` 会返回可读错误，UI 原样提示。
- 原始响应模型（`model.rs`）按实际响应结构定义，字段缺失用 `Option` 兜底，避免版本差异导致整页失败。
- 原生 ↔ Dart 的通道名与参数属于半公开契约，改动需同步 `lib/ble_key_bridge.dart` 等调用方。
