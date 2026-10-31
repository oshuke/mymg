//! 协议配置层（可插拔）。
//!
//! 这个仓库**不包含任何第三方服务的主机名、接口路径、应用标识或密钥**。
//! 所有与具体服务端相关的取值都在这里集中声明，并只从构建期环境变量读取；
//! 代码负责把它组织成请求，使用者负责填值。
//!
//! 未配置的项是空字符串，对应能力会在运行时**明确失败并提示未配置**，
//! 不会静默失败，也不会崩溃。填值方式见仓库根目录的
//! `config/protocol.example.env`（仅变量名）与 `docs/PROTOCOL.md`。
//!
//! 注入优先级（任选其一）：
//! 1. 构建前导出环境变量：`set -a; source config/protocol.env; set +a`
//! 2. 写入 `rust/.cargo/config.toml` 的 `[env]` 段
//! 3. 在 CI 的 secrets 中注入同名变量
//!
//! 之所以用编译期注入：Rust 侧常量会被 `opt-level=z` + `lto` 内联，
//! 运行时配置文件反而更难保密；编译期注入也让「未配置就不可能有默认值」成为硬约束。

macro_rules! proto {
    ($name:literal) => {
        match option_env!($name) {
            Some(v) => v,
            None => "",
        }
    };
}

// ──────────────────────────────────────────────────────────────
// 服务端地址
// ──────────────────────────────────────────────────────────────
/// 车况接口的完整 URL
pub const BASE_URL: &str = proto!("MYMG_STATUS_URL");
/// 车况/业务接口所在主机
pub const BASE_HOST: &str = proto!("MYMG_HOST_STATUS");
/// 账号（登录/验证码）接口所在主机
pub const LOGIN_HOST: &str = proto!("MYMG_HOST_LOGIN");

// ──────────────────────────────────────────────────────────────
// 账号链路路径
// ──────────────────────────────────────────────────────────────
pub const PATH_SEND_SMS: &str = proto!("MYMG_PATH_SEND_SMS");
pub const PATH_LOGIN: &str = proto!("MYMG_PATH_LOGIN");
pub const PATH_VEHICLE_LIST: &str = proto!("MYMG_PATH_VEHICLE_LIST");
pub const PATH_OUTSIDE_TOKEN: &str = proto!("MYMG_PATH_OUTSIDE_TOKEN");
pub const PATH_USER_INFO: &str = proto!("MYMG_PATH_USER_INFO");

/// 人机校验（滑块）站点标识
pub const CAPTCHA_ID: &str = proto!("MYMG_CAPTCHA_ID");
/// 业务侧 app 标识（请求体字段）
pub const APP_CODE: &str = proto!("MYMG_APP_CODE");
/// 业务侧品牌编码（请求体字段）
pub const BRAND_CODE: &str = proto!("MYMG_BRAND_CODE");
/// 客户端版本号（请求头/请求体字段）
pub const APP_VERSION: &str = proto!("MYMG_APP_VERSION");

// ──────────────────────────────────────────────────────────────
// 车况链路路径
// ──────────────────────────────────────────────────────────────
/// 车况读取（GET，1.1）
pub const PATH_STATUS_V11: &str = proto!("MYMG_PATH_STATUS_V11");
/// 车况读取（POST，1.2，读服务端缓存）
pub const PATH_STATUS_V12: &str = proto!("MYMG_PATH_STATUS_V12");
/// 请车辆主动上报一次车况
pub const PATH_STATUS_REQUEST: &str = proto!("MYMG_PATH_STATUS_REQUEST");

// ──────────────────────────────────────────────────────────────
// 控车链路路径
// ──────────────────────────────────────────────────────────────
pub const PATH_RANDOM_CODE: &str = proto!("MYMG_PATH_RANDOM_CODE");
pub const PATH_CHECK_PIN: &str = proto!("MYMG_PATH_CHECK_PIN");
pub const PATH_LOCK: &str = proto!("MYMG_PATH_LOCK");
pub const PATH_UNLOCK: &str = proto!("MYMG_PATH_UNLOCK");
pub const PATH_UNLOCK_BOOT: &str = proto!("MYMG_PATH_UNLOCK_BOOT");
pub const PATH_FIND: &str = proto!("MYMG_PATH_FIND");
pub const PATH_AC_ON: &str = proto!("MYMG_PATH_AC_ON");
pub const PATH_AC_OFF: &str = proto!("MYMG_PATH_AC_OFF");
pub const PATH_WIN_OPEN: &str = proto!("MYMG_PATH_WIN_OPEN");
pub const PATH_WIN_CLOSE: &str = proto!("MYMG_PATH_WIN_CLOSE");
pub const PATH_CONTROL_STATUS: &str = proto!("MYMG_PATH_CONTROL_STATUS");
pub const PATH_BLE_KEYS: &str = proto!("MYMG_PATH_BLE_KEYS");

/// 座椅加热控车：开源版留空（该能力未在公开协议中出现）。
/// 需要的人可以在自己的分支里填入候选路径，`control.rs` 会按序探测。
pub const PATH_SEAT_HEAT_CANDIDATES: &[&str] = &[];

// ──────────────────────────────────────────────────────────────
// 签名标识
// ──────────────────────────────────────────────────────────────
/// 品牌 A 的 appId（同时作为签名密钥）
pub const APP_ID_MG: &str = proto!("MYMG_APP_ID_A");
/// 品牌 B 的 appId（同时作为签名密钥）
pub const APP_ID_ROEWE: &str = proto!("MYMG_APP_ID_B");
/// 品牌 A 的 appType（请求头字段）
pub const APP_TYPE_MG: &str = proto!("MYMG_APP_TYPE_A");
/// 品牌 B 的 appType（请求头字段）
pub const APP_TYPE_ROEWE: &str = proto!("MYMG_APP_TYPE_B");

/// 设备型号（登录请求体字段，自填；未配置时用 generic）
pub fn mobile_type() -> &'static str {
    let v = proto!("MYMG_MOBILE_TYPE");
    if v.is_empty() { "generic" } else { v }
}

/// 设备厂商（登录请求体字段，自填；未配置时用 generic）
pub fn mobile_brand() -> &'static str {
    let v = proto!("MYMG_MOBILE_BRAND");
    if v.is_empty() { "generic" } else { v }
}

/// 计算设备指纹时参与反转的包名（自填）
pub const DEVICE_PKG: &str = proto!("MYMG_DEVICE_PKG");
/// 请求体里的业务 appId（品牌 A）
pub const BODY_APP_ID_MG: &str = proto!("MYMG_BODY_APP_ID_A");
/// 请求体里的业务 appId（品牌 B）
pub const BODY_APP_ID_RW: &str = proto!("MYMG_BODY_APP_ID_B");

// ──────────────────────────────────────────────────────────────
// 配置检查工具
// ──────────────────────────────────────────────────────────────

/// 该配置项是否已填。
pub fn is_set(v: &str) -> bool {
    !v.trim().is_empty()
}

/// 未配置时的统一错误文案（给 UI 直接显示用）。
pub fn not_configured(what: &str) -> String {
    format!(
        "未配置：{what} 为空。请按 config/protocol.example.env 填入配置后重新构建。"
    )
}

/// 校验一组配置项，返回第一个缺失项的错误。
pub fn require(items: &[(&str, &'static str)]) -> Result<(), String> {
    for (label, value) in items {
        if !is_set(value) {
            return Err(not_configured(label));
        }
    }
    Ok(())
}

/// 启动/构造客户端时的配置完整性检查。
/// 未配置时不 panic，而是返回可读错误，让 UI 直接提示用户去看 config 说明。
pub fn ensure_configured() -> Result<(), String> {
    let missing: Vec<&str> = [
        ("MYMG_HOST_STATUS", BASE_HOST),
        ("MYMG_HOST_LOGIN", LOGIN_HOST),
        ("MYMG_STATUS_URL", BASE_URL),
        ("MYMG_APP_ID_A", APP_ID_MG),
        ("MYMG_APP_TYPE_A", APP_TYPE_MG),
        ("MYMG_APP_CODE", APP_CODE),
        ("MYMG_BRAND_CODE", BRAND_CODE),
    ]
    .iter()
    .filter(|(_, v)| v.is_empty())
    .map(|(name, _)| *name)
    .collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "尚未配置协议参数：{}。\
             请复制 config/protocol.example.env 为 config/protocol.env 填好真实值，\
             或用 --dart-define / 环境变量在构建时注入。详见 docs/PROTOCOL.md。",
            missing.join(", ")
        ))
    }
}
