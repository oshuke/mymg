# 协议配置与扩展点

本仓库**不含任何厂商协议值**。所有与服务器/厂商相关的内容都以「构建期变量」的形式存在，
需要你自己填写。这一节说明每个变量的含义、注入方式，以及数字钥匙的扩展点契约。

---

## 1. 变量一览

完整模板见 [`config/protocol.example.env`](../config/protocol.example.env)。

### 1.1 服务器

| 变量 | 含义 |
|---|---|
| `MYMG_STATUS_URL` | 车况接口的完整 URL（含 `https://`） |
| `MYMG_HOST_STATUS` | 车况域名的 host（不含协议与路径） |
| `MYMG_HOST_LOGIN` | 登录/鉴权域名的 host（不含协议与路径） |

### 1.2 接口路径

| 变量 | 含义 |
|---|---|
| `MYMG_PATH_STATUS_V11` | 车况读取路径 |
| `MYMG_PATH_STATUS_V12` | 由令牌换取车辆状态（POST）路径 |
| `MYMG_PATH_STATUS_REQUEST` | 状态查询备用路径 |
| `MYMG_PATH_SEND_SMS` | 发送短信验证码 |
| `MYMG_PATH_LOGIN` | 短信验证码登录 |
| `MYMG_PATH_VEHICLE_LIST` | 已绑定车辆列表 |
| `MYMG_PATH_OUTSIDE_TOKEN` | 换取外部服务的访问令牌 |
| `MYMG_PATH_USER_INFO` | 用户信息 |
| `MYMG_PATH_RANDOM_CODE` | 控车第一步：取随机码 |
| `MYMG_PATH_CHECK_PIN` | 控车第二步：校验 PIN |
| `MYMG_PATH_LOCK` / `MYMG_PATH_UNLOCK` | 锁车 / 解锁 |
| `MYMG_PATH_UNLOCK_BOOT` | 开后备箱 |
| `MYMG_PATH_FIND` | 寻车（闪灯鸣笛） |
| `MYMG_PATH_AC_ON` / `MYMG_PATH_AC_OFF` | 空调开 / 关 |
| `MYMG_PATH_WIN_OPEN` / `MYMG_PATH_WIN_CLOSE` | 车窗开 / 关 |
| `MYMG_PATH_CONTROL_STATUS` | 控车结果轮询 |
| `MYMG_PATH_BLE_KEYS` | 蓝牙数字钥匙列表 |

### 1.3 登录与品牌参数

| 变量 | 含义 |
|---|---|
| `MYMG_CAPTCHA_ID` | 滑块/图形验证码的 captchaId（Dart 侧同名 `--dart-define`） |
| `MYMG_APP_CODE` | 应用标识（请求体里的 appId 一类） |
| `MYMG_BRAND_CODE` | 品牌编号 |
| `MYMG_APP_VERSION` | 客户端版本标识 |

### 1.4 签名

| 变量 | 含义 |
|---|---|
| `MYMG_APP_ID_A` / `MYMG_APP_TYPE_A` | 品牌 A 的签名密钥与应用类型 |
| `MYMG_APP_ID_B` / `MYMG_APP_TYPE_B` | 品牌 B 的签名密钥与应用类型 |
| `MYMG_BODY_APP_ID_A` / `MYMG_BODY_APP_ID_B` | 请求体里的 appId |
| `MYMG_DEVICE_PKG` | 计算 deviceId 用的包名 |

> 签名的**算法**在 `rust/src/vehicle/signutil.rs` 里是公开的（对若干字段做字典序排序拼接后
> HMAC-SHA256，再做 URL-safe Base64）。需要保密的只是密钥本身，而密钥不入库、由你注入。

### 1.5 设备指纹（可选）

| 变量 | 含义 |
|---|---|
| `MYMG_MOBILE_TYPE` / `MYMG_MOBILE_BRAND` | 设备型号/品牌串，留空则用 `generic` |

### 1.6 Dart 侧（`--dart-define`）

| 变量 | 含义 |
|---|---|
| `MYMG_OFFICIAL_PKG` | 官方 App 包名，仅用于「打开官方 App」按钮；不填则该按钮无效 |
| `MYMG_BLE_SERVICE_UUID` | 数字钥匙 GATT 服务 UUID（界面展示用；开源版原生无实现） |
| `MYMG_TOKEN_SUFFIX` | 访问令牌后缀校验，留空则不校验 |
| `MYMG_CAPTCHA_ID` | 与 Rust 侧同名变量，前端 WebView 滑块用 |

---

## 2. 注入方式

### Rust（编译期）

```rust
// rust/src/vehicle/protocol.rs
macro_rules! proto {
    ($name:literal) => {
        match option_env!($name) { Some(v) => v, None => "" }
    };
}
pub const BASE_HOST: &str = proto!("MYMG_HOST_STATUS");
```

因此变量必须在**构建时**存在于环境中：

```bash
set -a; . config/protocol.env; set +a
flutter build apk --release --target-platform android-arm64
```

### Dart（编译期常量）

```dart
static const String officialAppPackage =
    String.fromEnvironment('MYMG_OFFICIAL_PKG');
```

```bash
flutter build apk --release --dart-define=MYMG_OFFICIAL_PKG=com.example.app
```

### 未配置时的行为

`MgClient::new` / `AuthClient::new` / `ControlClient::new` 会先调用
`protocol::ensure_configured()`，缺关键项时返回：

> 尚未配置协议参数：…。请复制 config/protocol.example.env 为 config/protocol.env 填好真实值，
> 或用 --dart-define / 环境变量在构建时注入。详见 docs/PROTOCOL.md。

App 仍可启动、可浏览本地缓存的历史数据，联网操作会给出该提示。

---

## 3. 接到你自己的后端

本项目把「协议」隔离在两层，替换成本很低：

1. **`rust/src/vehicle/protocol.rs`** —— 域名/路径/参数全部集中在这里；
2. **`rust/src/vehicle/client.rs` / `auth.rs` / `control.rs`** —— 请求构造、令牌流程、控车链路。

如果你有自己的服务端，最小改法：

- 保留 `client.rs` 的请求/解析骨架，把 `protocol.rs` 的值指向自己的接口；
- 若鉴权方式不同，改 `auth.rs`（令牌获取与刷新）与 `signutil.rs`（签名）即可；
- `model.rs` 是 serde 强类型，按你的响应结构改字段（缺字段用 `Option` 兜底）。

---

## 4. 数字钥匙扩展点（MethodChannel）

开源版 `MymgBleKeyClient.kt` 是桩实现：所有调用直接返回「数字钥匙模块未内置」。
如果你自己实现了协议，替换该文件即可，**界面层不需要改**。

### 通道

- 名称：`mymg/ble`
- 方向：Dart 调用原生为 `invokeMethod`；原生回传为 `invokeMethod("event", payload)` 广播给所有引擎

### Dart → 原生方法

| 方法 | 参数 | 返回 |
|---|---|---|
| `bind` | 无 | `true` |
| `cachedMaterial` | 无 | `Map`（缓存的车端材料，供冷启动使用） |
| `probe` | `tboxMac`, `keyReference` | 探测结果 |
| `unlock` / `lock` / `trunk` / `drive` | `tboxMac`, `keyReference`, `userId`… | 指令结果 |
| `liftgateOpen` / `liftgateClose` | 同上 | 指令结果 |
| `disconnect` | 无 | `true` |
| `isConnected` | 无 | `bool` |
| `requestPermissions` | 无 | `true` |
| `setAutoDriveAfterUnlock` | `enabled` | 回显 |

### 原生 → Dart 事件

```dart
{'stage': 'connecting' | 'connected' | 'authing' | 'ready' | 'error',
 'message': '给人看的中文提示',
 'raw': '可选的调试信息'}
```

错误码：`NOT_INCLUDED` 表示开源版未内置该能力。

### 实现要点（给接入者）

- Android BLE 连接要有**连接超时**，否则 `busy` 状态会卡死整个 App；
- 会用到广播（多个 FlutterEngine 共存），参考 `MainActivity.kt` 里的 `Collections.synchronizedList`；
- 长时间链路建议配合前台服务（`MymgBleService`，已提供骨架）；
- 扫描与连接前建议先 `stopScan()`，避免射频被扫描占用导致连接失败。
