# 隐私说明

一句话：**没有遥测，没有统计，没有主动外发。** 所有数据默认只存在你自己的手机上。

## 本机存储了什么

| 数据 | 位置 | 是否加密 |
|---|---|---|
| 访问令牌（token） | `flutter_secure_storage` | 是（系统 KeyStore 保护） |
| 控车 PIN | `PinVault`（加密后存 secure storage） | 是 |
| 车辆信息、配置项 | `shared_preferences` | 否（可用系统备份加密） |
| 车况快照、历史数据 | 应用私有目录 SQLite | 否 |
| 车辆图片 | 应用私有目录 | 否 |
| 日志 | 仅 logcat（不落盘） | — |

卸载 App 即全部清除。应用私有目录位于 Android 沙箱内，其他应用无法直接读取（root 除外）。

## 什么时候会外发数据

只有三种情况，且**都必须由你主动配置或触发**：

1. **车况 / 控车请求** —— 发往你在 `config/protocol.env` 里配置的服务器；
2. **AI 车况解读** —— 你填入 AI 接口地址与 API Key 后，才会把车况摘要发给你配置的服务商；
3. **WebDAV 备份** —— 你填入地址与凭据后，才会把数据库快照上传到你自己的存储。

未配置时以上功能不可用，App 不会把数据发往任何第三方默认地址。

## 不收集的内容

- 不做设备指纹采集、不做埋点上报、不含广告/统计 SDK；
- 不上传位置、VIN、MAC、手机号到作者或任何第三方；
- 没有「作者服务器」——本项目不存在任何后端。

## 你在使用开源版时需要注意

1. `config/protocol.env` 含你自己的私有参数，**已加入 .gitignore，不要提交**；
2. 提 issue / 贴日志前，先删掉日志里的令牌、VIN、手机号、MAC（这些很容易被忽略）；
3. 截图里如果包含车架号（VIN）、车牌、精确定位，请打码后再发。

## 权限说明

| 权限 | 用途 |
|---|---|
| `INTERNET` / `ACCESS_NETWORK_STATE` | 请求车况与控制指令 |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | 地图显示车辆位置；Android 12 以下 BLE 扫描也需要 |
| `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` | 数字钥匙扩展点（开源版未内置实现） |
| `POST_NOTIFICATIONS` | 告警与控车结果通知 |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_*` | 后台刷新与 BLE 前台服务 |
| `USE_BIOMETRIC` / `USE_FINGERPRINT` | 查看/使用 PIN 前的身份校验 |
| `SYSTEM_ALERT_WINDOW` | 快捷控车浮层（可选） |
| `SCHEDULE_EXACT_ALARM` / `WAKE_LOCK` / `RECEIVE_BOOT_COMPLETED` | 预约提醒与后台任务 |
