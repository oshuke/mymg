# 构建说明

## 环境要求

| 工具 | 版本（开发时实测） | 说明 |
|---|---|---|
| Flutter | 3.47.x（Dart 3.13） | 需要支持 FRB 2.13 的 SDK |
| Rust | 1.98.x | 需安装 Android target |
| Android SDK | API 35+ | `compileSdk` 跟随 Flutter |
| Android NDK | 跟随 Flutter 版本 | Rust 交叉编译需要 |
| JDK | 17 | AGP 9.x 要求 |

## 一次性准备

```bash
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi   # 可选，本项目默认只打 arm64
```

`android/local.properties` 由 Flutter 自动生成（`flutter pub get` 或首次构建时），
里面是**你本机的 SDK/NDK 路径**，不要提交。

## 配置协议参数（必须）

```bash
cp config/protocol.example.env config/protocol.env
vi config/protocol.env          # 填入你自己的值
set -a; . config/protocol.env; set +a
```

这些变量在 **Rust 编译期**通过 `option_env!` 读取，所以：
- 必须在执行 `flutter build` 的同一个 shell 里 export
- 改完参数必须重新构建（增量构建也会重编 Rust，因为编译期值变了）

Dart 侧的可选参数用 `--dart-define`：

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=MYMG_OFFICIAL_PKG=com.example.officialapp \
  --dart-define=MYMG_BLE_SERVICE_UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  --dart-define=MYMG_TOKEN_SUFFIX=your-suffix
```

## 构建

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

只打 arm64 的原因：`android/app/build.gradle.kts` 里锁了 `abiFilters arm64-v8a`，
并在 `packaging.jniLibs.excludes` 里排掉了插件自带的 32 位/x86 so，避免体积膨胀与「v7a 设备装得上但启动崩」。

## 签名

`android/app/build.gradle.kts` 的 release 目前**沿用 debug 签名**（方便 `flutter run --release`）。
要分发给别人必须换成自己的 keystore：

```kotlin
// android/key.properties（已在 .gitignore 中）
storePassword=...
keyPassword=...
keyAlias=...
storeFile=/absolute/path/to/your.jks
```

## 调试

```bash
# Rust 日志（android_logger 桥接）
adb logcat -s mymg_core
# Flutter
flutter run --debug
```

## Rust 单元测试

```bash
cd rust
cargo test --offline
```

覆盖：签名算法已知向量、PIN 哈希形状、deviceId 形状、车况摘要换算。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `尚未配置协议参数` | 没 export `config/protocol.env` 或没重新构建 |
| 编译报 `undefined symbol 'frb_get_rust_content_hash'` | `rust/src/lib.rs` 的 `mod frb_generated;` 被注释或位置错误 |
| Gradle 拉依赖失败 | 配代理：`export HTTP_PROXY=http://127.0.0.1:7890`，或换国内镜像 |
| `flutter pub get` 卡住 | 设 `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| 增量构建后参数仍为空 | 编译期变量需要 `flutter clean` + 重新 export 再构建 |
