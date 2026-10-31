//! 暴露给 Flutter 的 API 层。
//!
//! 这些函数后续会被 `flutter_rust_bridge_codegen` 扫描并生成 Dart 绑定。
//! 目前先用同步包装（内部阻塞等待 tokio runtime），待接入 FRB 后改为 async。
//!
//! 错误统一用 `Result<T, ApiError>`（`ApiError = String`）。
//! 之前是 `Result<T, MgError>`，FRB codegen 把 `MgError` 序列化成 Dart 端的
//! `abstract class MgError implements RustOpaqueInterface`，catch 后
//! 只能看到 `Instance of'MgErrorImpl`，丢失业务码和描述。
//! 改成 String 后 FRB 直接映射成 Dart `String`，UI 能用 `.toString()` 拿到
//! 完整错误（如「服务端拒绝 [code=14700] mvcode错误」）。

use crate::vehicle::{
    ApiError, AuthClient, BluetoothKeysResponse, Brand, ControlClient, ControlIdentity,
    ControlOutcome, ControlStatusResult, LoginResult, MgClient, VehicleBrief, VehicleStatusResponse,
    VehicleSummary,
};

use std::sync::OnceLock;

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("mymg-rt")
            .enable_all()
            .build()
            .expect("创建 tokio runtime 失败")
    })
}

/// 把 Flutter 端"品牌选择"字符串翻译成 enum。
/// 约定："MG" / "MGLive"（brandCode=2）/ "Roewe"。大小写不敏感。
fn parse_brand(s: &str) -> Brand {
    if s.eq_ignore_ascii_case("roewe") || s == "1" {
        Brand::Roewe
    } else if s.eq_ignore_ascii_case("mglive") || s == "2" {
        Brand::MgLive
    } else {
        Brand::Mg
    }
}

/// 拉取完整车况（127 字段）。
pub fn fetch_vehicle_status(token: String, vin: String) -> Result<VehicleStatusResponse, ApiError> {
    let client = MgClient::new()?;
    Ok(runtime().block_on(client.get_vehicle_status(&token, &vin))?)
}

/// 拉取 UI 摘要（单位已换算）。
pub fn fetch_summary(token: String, vin: String) -> Result<VehicleSummary, ApiError> {
    let resp = fetch_vehicle_status(token, vin)?;
    Ok(VehicleSummary::from_response(&resp))
}

/// 用一段保存下来的 JSON 文本解析出摘要，便于离线调试 / 单元测试。
pub fn parse_summary_from_json(raw: String) -> Result<VehicleSummary, ApiError> {
    let resp: VehicleStatusResponse = serde_json::from_str(&raw)
        .map_err(|e| format!("JSON 解析失败: {}", e))?;
    Ok(VehicleSummary::from_response(&resp))
}

// ─── 账号登录（手机号 + 短信验证码）─────────────────────────

/// 请求发送手机号对应的短信验证码。
pub fn auth_send_sms_code(phone: String) -> Result<(), ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(client.send_sms_code(&phone))?)
}

/// 带易盾滑块结果发码（captchaId + NECaptchaValidate）
pub fn auth_send_sms_code_with_captcha(
    phone: String,
    captcha_id: String,
    captcha_validate: String,
) -> Result<(), ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(
        client.send_sms_code_with_captcha(&phone, &captcha_id, &captcha_validate),
    )?)
}

/// 带设备 ID 发码（与登录头一致，避免风控 14101）
pub fn auth_send_sms_code_full(
    phone: String,
    captcha_id: String,
    captcha_validate: String,
    device_id: String,
) -> Result<(), ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(client.send_sms_code_full(
        &phone,
        &captcha_id,
        &captcha_validate,
        &device_id,
    ))?)
}

/// 用短信验证码登录，成功后返回 token。
pub fn auth_login_by_sms(phone: String, code: String) -> Result<LoginResult, ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(client.login_by_sms(&phone, &code))?)
}

/// 带设备 ID 登录
pub fn auth_login_by_sms_device(
    phone: String,
    code: String,
    device_id: String,
) -> Result<LoginResult, ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(
        client.login_by_sms_device(&phone, &code, &device_id),
    )?)
}

/// 用登录拿到的 token 拉取账号下的车辆列表（自动取 VIN，无需用户手填）。
pub fn auth_fetch_vins(token: String) -> Result<Vec<VehicleBrief>, ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(client.fetch_vins(&token))?)
}

/// 登录后换车况 token / 激活
pub fn auth_activate_token(
    login_token: String,
    user_id: String,
    device_id: String,
) -> Result<String, ApiError> {
    let client = AuthClient::new()?;
    let uid = if user_id.is_empty() { None } else { Some(user_id.as_str()) };
    Ok(runtime().block_on(
        client.get_outside_token(&login_token, uid, &device_id),
    )?)
}

/// 用 token 补拉 userId
pub fn auth_fetch_user_id(
    token: String,
    device_id: String,
) -> Result<Option<String>, ApiError> {
    let client = AuthClient::new()?;
    Ok(runtime().block_on(client.fetch_user_id(&token, &device_id))?)
}

/// 带 userId 拉 VIN
pub fn auth_fetch_vins_user(
    token: String,
    user_id: String,
) -> Result<Vec<VehicleBrief>, ApiError> {
    let client = AuthClient::new()?;
    let uid = if user_id.is_empty() { None } else { Some(user_id.as_str()) };
    Ok(runtime().block_on(client.fetch_vins_user(&token, uid))?)
}

// ─── 远程控车（取随机码 → 校验 PIN → 下发指令 → 轮询结果）──────────

fn identity(
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> ControlIdentity {
    ControlIdentity {
        token,
        vin,
        pin,
        user_id,
        mobile,
        header_device_id,
    }
}

/// 进程级 ControlClient（共享 HTTP 连接池）。
fn control_client() -> &'static ControlClient {
    static CLIENT: OnceLock<ControlClient> = OnceLock::new();
    CLIENT.get_or_init(|| ControlClient::new().expect("创建 ControlClient 失败"))
}

/// 锁车（官方三步鉴权 + requestLock）
pub fn vehicle_lock(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.lock(parse_brand(&brand), &id))?)
}

/// 兼容旧调试：已废弃 mvcode 路径（现网无此字段），直接走标准锁车
pub fn vehicle_lock_with_mvcode(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    _mvcode: String,
) -> Result<ControlOutcome, ApiError> {
    // 旧调用方缺 user_id/mobile/header_device_id，无法完整鉴权
    Err("mvcode 路径已废弃：请用 vehicle_lock（需 user_id/mobile/header_device_id）".into())
}

/// PIN 四级哈希（与官方一致，供调试）
pub fn pin_hash(pin_plain: String, user_id: String, vin: String, mobile: String, rav_code: String) -> String {
    crate::vehicle::signutil::compute_pin_hash(&pin_plain, &user_id, &vin, &mobile, &rav_code)
}

/// API deviceId（与官方一致）
pub fn api_device_id(header_device_id: String) -> String {
    crate::vehicle::signutil::compute_api_device_id(&header_device_id)
}

/// 解锁
pub fn vehicle_unlock(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.unlock(parse_brand(&brand), &id))?)
}

/// 开后备箱
pub fn vehicle_unlock_boot(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.unlock_boot(parse_brand(&brand), &id))?)
}

/// 鸣笛闪灯找车
pub fn vehicle_find_vehicle(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    is_flashing: bool,
    horn_volume: u8,
    time_length_s: u8,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.find_vehicle(
        parse_brand(&brand),
        &id,
        is_flashing,
        horn_volume,
        time_length_s,
    ))?)
}

/// 启动空调
pub fn vehicle_ac_on(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    target_temp_c: u8,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.ac_on(parse_brand(&brand), &id, target_temp_c))?)
}

/// 关闭空调
pub fn vehicle_ac_off(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.ac_off(parse_brand(&brand), &id))?)
}

/// 座椅加热。seat: "1"=主驾 "2"=副驾；on=true 开 / false 关
pub fn vehicle_seat_heat(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    seat: String,
    on: bool,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(
        client.seat_heat(parse_brand(&brand), &id, &seat, on),
    )?)
}

/// 拉取蓝牙/数字钥匙列表（无需 PIN）
pub fn vehicle_fetch_bluetooth_keys(
    brand: String,
    token: String,
    vin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
) -> Result<BluetoothKeysResponse, ApiError> {
    let client = control_client();
    let id = identity(token, vin, String::new(), user_id, mobile, header_device_id);
    Ok(runtime().block_on(
        client.fetch_bluetooth_keys(parse_brand(&brand), &id),
    )?)
}

/// 查询控车指令执行结果（单次；Dart 侧自行轮询，避免内外双轮询叠请求）
pub fn vehicle_get_control_status(
    brand: String,
    token: String,
    vin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    command_id: i64,
) -> Result<ControlStatusResult, ApiError> {
    let client = control_client();
    // 查询接口不需要 pin，占位空串
    let id = identity(token, vin, String::new(), user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.get_control_status(
        parse_brand(&brand),
        &id,
        command_id,
    ))?)
}

/// 开窗
pub fn vehicle_window_open(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    target: String,
    position: u8,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.window_open(
        parse_brand(&brand),
        &id,
        &target,
        position,
    ))?)
}

/// 关窗
pub fn vehicle_window_close(
    brand: String,
    token: String,
    vin: String,
    pin: String,
    user_id: String,
    mobile: String,
    header_device_id: String,
    target: String,
    position: u8,
) -> Result<ControlOutcome, ApiError> {
    let client = control_client();
    let id = identity(token, vin, pin, user_id, mobile, header_device_id);
    Ok(runtime().block_on(client.window_close(
        parse_brand(&brand),
        &id,
        &target,
        position,
    ))?)
}