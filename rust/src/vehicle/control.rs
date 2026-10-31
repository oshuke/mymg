//! 远程控车链路。
//!
//! 一次控车分四步，全部是 POST `data={json}` + 签名头：
//!
//! 1. 取一次性随机码
//! 2. 用 PIN 换授权码（PIN 走四级哈希，见 [`super::signutil::compute_pin_hash`]）
//! 3. 下发具体指令（`auth_code` = 上一步的授权码），拿 `command_id`
//! 4. 按 `command_id` 轮询指令结果
//!
//! 主机、路径、appType 与签名标识全部由 [`super::protocol`] 注入，
//! 仓库内不含任何真实取值；未配置时调用会在入口处直接报「未配置」。
//!
//! # 签名
//!
//! 对 `[path, header_timestamp, data_json, app_type]` 排序后无分隔符拼接，
//! 做 HMAC-SHA256，再转 URL-safe Base64（见 [`super::signutil::compute_sign`]）。
//! 时间戳取 **HTTP 头 timestamp**（可与 body 里的 timestamp 不同）。
//!
//! # 请求公共字段
//!
//! ```text
//! auth_type / appId / vin / nonce / brandCode / timestamp / token / auth_code
//! ```
//!
//! 请求头额外带 Uuid / DeviceID / token / brandCode / timestamp / app-type / sign。

use serde::{Deserialize, Serialize};

use super::client::ApiError;
use super::protocol::{
    BASE_HOST,
    PATH_AC_OFF, PATH_AC_ON, PATH_BLE_KEYS, PATH_CHECK_PIN, PATH_CONTROL_STATUS, PATH_FIND,
    PATH_LOCK, PATH_RANDOM_CODE, PATH_SEAT_HEAT_CANDIDATES, PATH_UNLOCK, PATH_UNLOCK_BOOT,
    PATH_WIN_CLOSE, PATH_WIN_OPEN,
};
use super::signutil::{
    app_id_for_brand, app_type_for_brand, body_app_id_for_brand, compute_api_device_id,
    compute_pin_hash, compute_sign, generate_nonce,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Brand {
    Mg,
    Roewe,
    MgLive,
}

impl Brand {
    pub fn code(self) -> &'static str {
        match self {
            Brand::Mg => "0",
            Brand::Roewe => "1",
            Brand::MgLive => "2",
        }
    }
}

/// 控车身份（一次操作所需全部参数）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlIdentity {
    pub token: String,
    pub vin: String,
    /// 明文车控 PIN（6 位等）
    pub pin: String,
    /// 账号 userId（字符串数字）
    pub user_id: String,
    /// 绑定手机号（PIN 哈希第三层输入）
    pub mobile: String,
    /// 头 DeviceID/Uuid（设备稳定串，MYMG 可持久化 android_id）
    pub header_device_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlOutcome {
    pub accepted: bool,
    pub request_id: Option<String>,
    pub message: Option<String>,
    /// requestLock 成功时的 command_id
    pub command_id: Option<i64>,
}

/// 控车指令执行结果（getControlStatus）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlStatusResult {
    /// 0/1/2 等服务端码；官方字段 commandResult
    pub command_result: Option<i64>,
    pub command_status: Option<String>,
    pub command_result_switch: Option<bool>,
    pub failure_type: Option<String>,
    pub failure_msg: Option<String>,
    pub done: bool,
    pub success: bool,
    pub raw: String,
}

/// 蓝牙数字钥匙条目（字段随服务端扩展，保留原始 JSON）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BluetoothKeyInfo {
    pub license_no: Option<String>,
    pub vin: Option<String>,
    pub mac: Option<String>,
    pub secret_key: Option<String>,
    pub aes_key: Option<String>,
    pub name: Option<String>,
    pub status: Option<String>,
    pub raw: serde_json::Value,
}

/// bluetoothAndDigitalKeys 响应
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BluetoothKeysResponse {
    pub digital_key_list: Option<Vec<BluetoothKeyInfo>>,
    pub bluetooth_key_list: Option<Vec<BluetoothKeyInfo>>,
    pub raw: String,
}

pub struct ControlClient {
    http: reqwest::Client,
}

/// 进程级共享 HTTP（连接池/TLS 只握手一次）。
pub(crate) fn shared_http() -> &'static reqwest::Client {
    use std::sync::OnceLock;
    static HTTP: OnceLock<reqwest::Client> = OnceLock::new();
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(12))
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .pool_max_idle_per_host(4)
            .user_agent("okhttp/4.9.1")
            .build()
            .expect("创建共享 HTTP Client 失败")
    })
}

impl Default for ControlClient {
    fn default() -> Self {
        Self::new().expect("创建 ControlClient 失败")
    }
}

impl ControlClient {
    pub fn new() -> Result<Self, ApiError> {
        super::protocol::ensure_configured()?;
        Ok(Self { http: shared_http().clone() })
    }

    /// 通用 POST：官方头 + form data + sign（header 时间戳）。
    async fn post(
        &self,
        path: &str,
        extra: serde_json::Map<String, serde_json::Value>,
        brand: Brand,
        id: &ControlIdentity,
    ) -> Result<serde_json::Value, ApiError> {
        self.post_on(BASE_HOST, path, extra, brand, id).await
    }

    async fn post_on(
        &self,
        host: &str,
        path: &str,
        extra: serde_json::Map<String, serde_json::Value>,
        brand: Brand,
        id: &ControlIdentity,
    ) -> Result<serde_json::Value, ApiError> {
        let header_ts = now_ms();
        let nonce = generate_nonce();
        let app_type = app_type_for_brand(brand);
        let sign_key = app_id_for_brand(brand);
        let body_app = body_app_id_for_brand(brand);

        let mut data = serde_json::Map::new();
        data.insert("auth_type".into(), serde_json::json!("2"));
        data.insert("appId".into(), serde_json::json!(body_app));
        data.insert("vin".into(), serde_json::json!(id.vin));
        data.insert("nonce".into(), serde_json::json!(nonce));
        data.insert("brandCode".into(), serde_json::json!(brand.code()));
        data.insert("timestamp".into(), serde_json::json!(header_ts));
        data.insert("token".into(), serde_json::json!(id.token));
        for (k, v) in extra {
            data.insert(k, v);
        }
        let data_val = serde_json::Value::Object(data);
        let data_str = serde_json::to_string(&data_val)
            .map_err(|e| format!("JSON 序列化失败: {}", e))?;

        // sign 必须用 header 时间戳 + 紧凑 data_json
        let sign = compute_sign(app_type, path, &header_ts, &data_str, sign_key);

        let api_device = compute_api_device_id(&id.header_device_id);
        let brand_code = brand.code().to_string();

        log::info!("POST {}\n  data={}", path, data_str);

        let resp = self
            .http
            .post(format!("https://{}{}", host, path))
            .header("Uuid", &id.header_device_id)
            .header("DeviceID", &id.header_device_id)
            .header("os", "android")
            .header("osVersion", "34")
            .header("x-client-id", "APP")
            .header("versionCode", "146")
            .header("token", &id.token)
            .header("brandCode", &brand_code)
            .header("timestamp", &header_ts)
            .header("app-type", app_type)
            .header("sign", &sign)
            .header("User-Agent", "okhttp/4.9.1")
            .form(&[("data", data_str.as_str())])
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {}", e))?;

        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取响应失败: {}", e))?;
        log::info!("POST {host}{path} status={} body={}", status, text);
        let _ = api_device;
        parse_json_object(&text)
    }

        /// randomCodeWithToken → rav_code
    async fn fetch_rav_code(&self, brand: Brand, id: &ControlIdentity) -> Result<String, ApiError> {
        let mut extra = serde_json::Map::new();
        extra.insert("uuid".into(), serde_json::json!(id.header_device_id));
        if !id.user_id.is_empty() {
            extra.insert("userId".into(), serde_json::json!(id.user_id));
        }
        // 先主域名，再备用域名（部分接口只在其中一个上可用）
        let mut last_err = String::new();
        for host in [BASE_HOST, super::protocol::LOGIN_HOST] {
            match self.post_on(host, PATH_RANDOM_CODE, extra.clone(), brand, id).await {
                Ok(v) => {
                    if let Some(s) = v.pointer("/data/rav_code").and_then(|x| x.as_str()) {
                        if !s.is_empty() {
                            return Ok(s.to_string());
                        }
                    }
                    let e = v.get("err_resp");
                    let code = e
                        .and_then(|x| x.get("code"))
                        .map(|x| x.to_string().trim_matches('"').to_string())
                        .unwrap_or_default();
                    let msg = e
                        .and_then(|x| x.get("msg").or_else(|| x.get("desc")))
                        .map(|x| x.to_string().trim_matches('"').to_string())
                        .unwrap_or_default();
                    if code == "14101" || msg.contains("登录态") {
                        last_err = format!("{} 上 14101/登录态: {msg}", host);
                        continue;
                    }
                    return Err(Self::rav_error(&v, host));
                }
                Err(e) => {
                    last_err = format!("{} HTTP: {e}", host);
                    continue;
                }
            }
        }
        Err(format!(
            "解锁失败（14101 登录态失效）：各域名均拒绝 randomCodeWithToken。\n\
             {last_err}\n\
             token 尾缀={} userId={} deviceId={} brand={}\n\
             请：重新登录；或用「令牌登录」粘贴新的访问令牌；\
             并确认设置→远程控车 与登录一致。",
            Self::token_tail(&id.token),
            id.user_id,
            id.header_device_id,
            brand.code()
        ))
    }

    fn token_tail(t: &str) -> String {
        if t.is_empty() {
            return "(空)".into();
        }
        let n = t.len().min(12);
        format!("…{}", &t[t.len() - n..])
    }

    fn rav_error(v: &serde_json::Value, host: &str) -> String {
        let err = v.get("err_resp");
        let code = err
            .and_then(|e| e.get("code"))
            .or_else(|| v.get("code"))
            .map(|x| x.to_string().trim_matches('"').to_string())
            .unwrap_or_default();
        let msg = err
            .and_then(|e| e.get("msg").or_else(|| e.get("desc")))
            .or_else(|| v.get("msg"))
            .map(|x| x.to_string().trim_matches('"').to_string())
            .unwrap_or_default();
        if code == "14101" || msg.contains("登录态") || msg.contains("重新登录") {
            return format!(
                "解锁失败（14101 登录态失效）@{host}：\n\
                 randomCodeWithToken 拒绝了当前 token。\nmsg={msg}\n\
                 请退出后重新登录；或用「令牌登录」粘贴新的访问令牌。"
            );
        }
        let raw = v.to_string();
        let snip = if raw.len() > 240 { &raw[..240] } else { raw.as_str() };
        format!(
            "解锁失败：服务端未返回 rav_code @{host}\n\
             code={code} msg={msg}\n响应：{snip}"
        )
    }

    /// checkPINCode → pvCode（即 auth_code）
    async fn fetch_pv_code(&self, brand: Brand, id: &ControlIdentity, rav_code: &str) -> Result<String, ApiError> {
        let api_device = compute_api_device_id(&id.header_device_id);
        let pin_hash = compute_pin_hash(&id.pin, &id.user_id, &id.vin, &id.mobile, rav_code);
        let mut extra = serde_json::Map::new();
        extra.insert("deviceId".into(), serde_json::json!(api_device));
        extra.insert("pin".into(), serde_json::json!(pin_hash));
        let v = self.post(PATH_CHECK_PIN, extra, brand, id).await?;

        let is_right = v
            .pointer("/data/isRight")
            .and_then(|x| x.as_str())
            .map(|s| s.eq_ignore_ascii_case("true") || s == "1")
            .unwrap_or(false);
        if !is_right {
            // checkPIN 的 err_resp 与 data 混用；一律解析出来
            let e = v.get("err_resp");
            let msg = e
                .and_then(|x| x.get("msg").or_else(|| x.get("desc")))
                .or_else(|| v.pointer("/data/errorCode"))
                .or_else(|| v.pointer("/data/msg"))
                .or_else(|| v.get("msg"))
                .and_then(|x| x.as_str())
                .unwrap_or("PIN 校验失败");
            let code = e
                .and_then(|x| x.get("code"))
                .or_else(|| v.pointer("/data/code"))
                .map(|x| x.to_string().trim_matches('"').to_string())
                .unwrap_or_default();
            if code == "14101" || msg.contains("登录态") || msg.contains("重新登录") {
                return Err(format!(
                    "checkPINCode 阶段登录态失效（14101）。\n\
                     userId={} VIN={} mobile={} brand={} token尾={}\n\
                     请重新登录后再试；若车况页正常、仅控车 14101，\
                     说明控车链路 token 与车况 token 可能不是同一颗。",
                    id.user_id,
                    id.vin,
                    id.mobile,
                    brand.code(),
                    Self::token_tail(&id.token)
                ));
            }
            return Err(format!(
                "checkPINCode 拒绝: {}\n\
                 PIN 校验哈希依赖：PIN + userId + VIN + 手机号 + rav_code。\n\
                 userId={} VIN={} mobile={} brand={}\n\
                 若密码本身无误，请核对：设置→远程控车 里的 userId/手机号\
                 是否与登录一致；VIN 是否为本车。",
                msg,
                id.user_id,
                id.vin,
                id.mobile,
                brand.code()
            ));
        }
        v.pointer("/data/pvCode")
            .and_then(|x| x.as_str())
            .map(String::from)
            .ok_or_else(|| "checkPINCode 响应缺少 pvCode".to_string())
    }

    /// 完成鉴权，返回 auth_code
    async fn authorize(&self, brand: Brand, id: &ControlIdentity) -> Result<String, ApiError> {
        let rav = self.fetch_rav_code(brand, id).await?;
        self.fetch_pv_code(brand, id, &rav).await
    }

    async fn rke(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        path: &str,
        mut extra: serde_json::Map<String, serde_json::Value>,
    ) -> Result<ControlOutcome, ApiError> {
        let auth_code = self.authorize(brand, id).await?;
        extra.insert("auth_code".into(), serde_json::json!(auth_code));
        let v = self.post(path, extra, brand, id).await?;
        Ok(ControlOutcome::from_json(&v))
    }

    pub async fn lock(&self, brand: Brand, id: &ControlIdentity) -> Result<ControlOutcome, ApiError> {
        self.rke(brand, id, PATH_LOCK, serde_json::Map::new()).await
    }

    pub async fn unlock(&self, brand: Brand, id: &ControlIdentity) -> Result<ControlOutcome, ApiError> {
        self.rke(brand, id, PATH_UNLOCK, serde_json::Map::new()).await
    }

    pub async fn unlock_boot(&self, brand: Brand, id: &ControlIdentity) -> Result<ControlOutcome, ApiError> {
        self.rke(brand, id, PATH_UNLOCK_BOOT, serde_json::Map::new()).await
    }

    pub async fn find_vehicle(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        is_flashing: bool,
        _horn_volume: u8,
        _time_length_s: u8,
    ) -> Result<ControlOutcome, ApiError> {
        // 寻车参数：horn_volume="low" / time_length="30" / is_flashing="true"
        // 只发一次（rke 已含前两步鉴权，重复发送极易触发服务端限频）
        let mut extra = serde_json::Map::new();
        extra.insert(
            "is_flashing".into(),
            serde_json::json!(if is_flashing { "true" } else { "false" }),
        );
        // 官方固定 low/30；参数仅作文案兼容，不再回写 body
        let _ = (_horn_volume, _time_length_s);
        extra.insert("horn_volume".into(), serde_json::json!("low"));
        extra.insert("time_length".into(), serde_json::json!("30"));
        self.rke(brand, id, PATH_FIND, extra).await
    }

    pub async fn ac_on(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        target_temp_c: u8,
    ) -> Result<ControlOutcome, ApiError> {
        if !(16..=30).contains(&target_temp_c) {
            return Err("温度需在 16~30 ℃".to_string());
        }
        let mut extra = serde_json::Map::new();
        extra.insert(
            "target_temperature".into(),
            serde_json::json!(target_temp_c.to_string()),
        );
        // 空调与锁车同样走完整鉴权并带 auth_code
        self.rke(brand, id, PATH_AC_ON, extra).await
    }

    pub async fn ac_off(&self, brand: Brand, id: &ControlIdentity) -> Result<ControlOutcome, ApiError> {
        self.rke(brand, id, PATH_AC_OFF, serde_json::Map::new()).await
    }

    pub async fn window_open(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        target: &str,
        position: u8,
    ) -> Result<ControlOutcome, ApiError> {
        self.window(brand, id, target, position, PATH_WIN_OPEN).await
    }

    pub async fn window_close(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        target: &str,
        position: u8,
    ) -> Result<ControlOutcome, ApiError> {
        self.window(brand, id, target, position, PATH_WIN_CLOSE).await
    }

    async fn window(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        target: &str,
        position: u8,
        path: &str,
    ) -> Result<ControlOutcome, ApiError> {
        let mut extra = serde_json::Map::new();
        extra.insert("target".into(), serde_json::json!(target));
        extra.insert("position".into(), serde_json::json!(position.to_string()));
        self.rke(brand, id, path, extra).await
    }

    /// 查询控车结果。**不需要 auth_code / PIN**（官方 dump 已确认）。
    pub async fn get_control_status(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        command_id: i64,
    ) -> Result<ControlStatusResult, ApiError> {
        // 官方 body：command_id, appId, vin, nonce, brandCode, timestamp, token
        // 不含 auth_type / auth_code
        let header_ts = now_ms();
        let nonce = generate_nonce();
        let app_type = app_type_for_brand(brand);
        let sign_key = app_id_for_brand(brand);
        let body_app = body_app_id_for_brand(brand);

        let mut data = serde_json::Map::new();
        data.insert("command_id".into(), serde_json::json!(command_id));
        data.insert("appId".into(), serde_json::json!(body_app));
        data.insert("vin".into(), serde_json::json!(id.vin));
        data.insert("nonce".into(), serde_json::json!(nonce));
        data.insert("brandCode".into(), serde_json::json!(brand.code()));
        data.insert("timestamp".into(), serde_json::json!(header_ts));
        data.insert("token".into(), serde_json::json!(id.token));
        let data_str = serde_json::to_string(&serde_json::Value::Object(data))
            .map_err(|e| format!("JSON 序列化失败: {}", e))?;
        let sign = compute_sign(app_type, PATH_CONTROL_STATUS, &header_ts, &data_str, sign_key);

        log::info!("POST {}\n  data={}", PATH_CONTROL_STATUS, data_str);
        let resp = self
            .http
            .post(format!("https://{}{}", BASE_HOST, PATH_CONTROL_STATUS))
            .header("Uuid", &id.header_device_id)
            .header("DeviceID", &id.header_device_id)
            .header("os", "android")
            .header("osVersion", "34")
            .header("x-client-id", "APP")
            .header("versionCode", "146")
            .header("token", &id.token)
            .header("brandCode", brand.code())
            .header("timestamp", &header_ts)
            .header("app-type", app_type)
            .header("sign", &sign)
            .header("User-Agent", "okhttp/4.9.1")
            .form(&[("data", data_str.as_str())])
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {}", e))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取响应失败: {}", e))?;
        log::info!("RESP status={} body={}", status, text);
        let v = parse_json_object(&text)?;
        let d = v.pointer("/data").cloned().unwrap_or(v.clone());
        let command_result = d
            .get("commandResult")
            .or_else(|| d.get("command_result"))
            .and_then(|x| x.as_i64());
        let command_status = d
            .get("commandStatus")
            .or_else(|| d.get("command_status"))
            .and_then(|x| x.as_str())
            .map(String::from);
        let command_result_switch = d
            .get("commandResultSwitch")
            .or_else(|| d.get("command_result_switch"))
            .and_then(|x| x.as_bool());
        let failure_type = d
            .get("failureType")
            .or_else(|| d.get("failure_type"))
            .and_then(|x| x.as_str())
            .map(String::from);
        let failure_msg = d
            .get("failureMsg")
            .or_else(|| d.get("failure_msg"))
            .and_then(|x| x.as_str())
            .map(String::from);

        // 官方常见：commandStatus 为 running/success/fail；commandResultSwitch 为最终是否成功
        let st = command_status.as_deref().unwrap_or("").to_ascii_lowercase();
        // done 只认终态；commandResultSwitch=false 仍是进行中，不能当 done
        let done = st.contains("success")
            || st.contains("fail")
            || st.contains("error")
            || st.contains("complete")
            || command_result_switch == Some(true)
            || (command_result_switch == Some(false) && st.is_empty() && failure_msg.is_some());
        let success = command_result_switch.unwrap_or(false)
            || st.contains("success")
            || st.contains("complete")
            || command_result == Some(0)
            || command_result == Some(200);

        Ok(ControlStatusResult {
            command_result,
            command_status,
            command_result_switch,
            failure_type,
            failure_msg,
            done,
            success,
            raw: text,
        })
    }

    /// 轮询控车结果若干次，直到完成或超时。
    pub async fn poll_control_status(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        command_id: i64,
    ) -> Result<ControlStatusResult, ApiError> {
        let mut last = None;
        for i in 0..3 {
            tokio::time::sleep(std::time::Duration::from_millis(800 + i * 300)).await;
            let r = self.get_control_status(brand, id, command_id).await?;
            let done = r.done;
            last = Some(r);
            if done {
                break;
            }
        }
        last.ok_or_else(|| "getControlStatus 未返回结果".to_string())
    }

    /// 拉取账号下的蓝牙/数字钥匙列表（无需 PIN）。
    /// body 字段：userId, appId, brandCode, nonce, timestamp, token
    /// 主/备两个主机各试一次
    pub async fn fetch_bluetooth_keys(
        &self,
        brand: Brand,
        id: &ControlIdentity,
    ) -> Result<BluetoothKeysResponse, ApiError> {
        let mut last_err = String::new();
        for host in [BASE_HOST, super::protocol::LOGIN_HOST] {
            match self.fetch_bluetooth_keys_on(host, brand, id).await {
                Ok(r) => return Ok(r),
                Err(e) => {
                    last_err = format!("[{}] {}", host, e);
                    log::warn!("ble keys failed on {}: {}", host, e);
                }
            }
        }
        Err(format!(
            "拉钥匙失败：{}。请重新验证码登录后重试。",
            last_err
        ))
    }

    async fn fetch_bluetooth_keys_on(
        &self,
        host: &str,
        brand: Brand,
        id: &ControlIdentity,
    ) -> Result<BluetoothKeysResponse, ApiError> {
        let header_ts = now_ms();
        let nonce = generate_nonce();
        let app_type = app_type_for_brand(brand);
        let sign_key = app_id_for_brand(brand);
        let body_app = body_app_id_for_brand(brand);

        let mut data = serde_json::Map::new();
        data.insert("userId".into(), serde_json::json!(id.user_id));
        data.insert("appId".into(), serde_json::json!(body_app));
        data.insert("brandCode".into(), serde_json::json!(brand.code()));
        data.insert("nonce".into(), serde_json::json!(nonce));
        data.insert("timestamp".into(), serde_json::json!(header_ts));
        data.insert("token".into(), serde_json::json!(id.token));
        let data_str = serde_json::to_string(&serde_json::Value::Object(data))
            .map_err(|e| format!("JSON 序列化失败: {}", e))?;
        let sign = compute_sign(app_type, PATH_BLE_KEYS, &header_ts, &data_str, sign_key);

        log::info!("POST https://{}{}\n  data={}", host, PATH_BLE_KEYS, data_str);
        let resp = self
            .http
            .post(format!("https://{}{}", host, PATH_BLE_KEYS))
            .header("Uuid", &id.header_device_id)
            .header("DeviceID", &id.header_device_id)
            .header("os", "android")
            .header("osVersion", "34")
            .header("x-client-id", "APP")
            .header("versionCode", "146")
            .header("Model", "ehs")
            .header("token", &id.token)
            .header("brandCode", brand.code())
            .header("timestamp", &header_ts)
            .header("app-type", app_type)
            .header("sign", &sign)
            .header("User-Agent", "okhttp/4.9.1")
            .form(&[("data", data_str.as_str())])
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {}", e))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取响应失败: {}", e))?;
        log::info!("RESP status={} body={}", status, text);
        let v = parse_json_object(&text)?;

        if let Some(e) = v.get("err_resp") {
            let code = e
                .get("code")
                .map(|c| match c {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .unwrap_or_else(|| "?".into());
            let msg = e
                .get("msg")
                .or_else(|| e.get("desc"))
                .and_then(|m| m.as_str())
                .unwrap_or("未知错误");
            return Err(format!("服务端拒绝 [code={}] {}", code, msg));
        }

        fn parse_list(v: &serde_json::Value, key: &str) -> Option<Vec<BluetoothKeyInfo>> {
            let arr = v.pointer(&format!("/data/{}", key))?.as_array()?;
            Some(
                arr.iter()
                    .map(|item| BluetoothKeyInfo {
                        license_no: item
                            .get("licenseNo")
                            .or_else(|| item.get("license_no"))
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        vin: item
                            .get("vin")
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        mac: item
                            .get("tbox_mac")
                            .or_else(|| item.get("tboxMac"))
                            .or_else(|| item.get("macAddress"))
                            .or_else(|| item.get("mac"))
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        secret_key: item
                            .get("secret_key")
                            .or_else(|| item.get("secretKey"))
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        aes_key: item
                            .get("aes_key")
                            .or_else(|| item.get("aesKey"))
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        name: item
                            .get("owner_name")
                            .or_else(|| item.get("user_name"))
                            .or_else(|| item.get("name"))
                            .and_then(|x| x.as_str())
                            .map(String::from),
                        status: item
                            .get("status")
                            .map(|x| match x {
                                serde_json::Value::String(s) => s.clone(),
                                serde_json::Value::Number(n) => n.to_string(),
                                other => other.to_string(),
                            })
                            .filter(|s| s != "null"),
                        raw: item.clone(),
                    })
                    .collect(),
            )
        }

        Ok(BluetoothKeysResponse {
            digital_key_list: parse_list(&v, "digital_key_list"),
            bluetooth_key_list: parse_list(&v, "bluetooth_key_list"),
            raw: text,
        })
    }

    /// 座椅加热开关。seat: "1"=主驾/左, "2"=副驾/右
    ///
    /// 官方 2.2.4 `VehicleControlAction` 仅 8 种（锁/解/尾/寻/空调/窗），
    /// APK 字面量里没有 requestSeatHeat；这里按同类路径探测，失败时带路径提示。
    pub async fn seat_heat(
        &self,
        brand: Brand,
        id: &ControlIdentity,
        seat: &str,
        on: bool,
    ) -> Result<ControlOutcome, ApiError> {
        let switch = if on { "1" } else { "0" };
        let mut last_err = String::from("no path tried");
        for (i, path) in PATH_SEAT_HEAT_CANDIDATES.iter().enumerate() {
            let mut extra = serde_json::Map::new();
            // 贴近窗口/空调的官方字段风格 + 座椅位开关两种写法
            extra.insert("seatPosition".into(), serde_json::json!(seat));
            extra.insert("switch".into(), serde_json::json!(switch));
            extra.insert("target".into(), serde_json::json!(seat));
            extra.insert(
                "position".into(),
                serde_json::json!(if on { "1" } else { "0" }),
            );
            extra.insert("action".into(), serde_json::json!(switch));
            match self.rke(brand, id, path, extra).await {
                Ok(v) => {
                    if v.accepted {
                        log::info!("seat_heat ok via {}", path);
                        return Ok(v);
                    }
                    last_err = v
                        .message
                        .clone()
                        .unwrap_or_else(|| format!("{} 拒绝", path));
                    // 明确 404/接口不存在时换下一候选；业务拒绝（PIN/风控）直接返回
                    let looks_missing = last_err.contains("404")
                        || last_err.contains("不存在")
                        || last_err.contains("not found")
                        || last_err.contains("path");
                    if !looks_missing {
                        return Ok(v);
                    }
                }
                Err(e) => {
                    last_err = format!("{}: {}", path, e);
                    // 网络级错误不必换路径
                    if e.contains("HTTP 请求失败") || e.contains("timeout") {
                        return Err(e);
                    }
                }
            }
            log::warn!("seat_heat path[{}] failed: {}", i, last_err);
        }
        Err(format!(
            "座椅加热接口未命中（官方 2.2.4 无独立枚举）。最后错误：{}。\
             如果你知道正确的路径，可在 config 里补充候选值。",
            last_err
        ))
    }
}

impl ControlOutcome {
    fn from_json(v: &serde_json::Value) -> Self {
        let request_id = v
            .get("req_id")
            .or_else(|| v.get("requestId"))
            .and_then(|x| x.as_str())
            .map(String::from);
        let command_id = v
            .pointer("/data/command_id")
            .and_then(|x| x.as_i64());

        if let Some(e) = v.get("err_resp") {
            let code = e
                .get("code")
                .map(|c| match c {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .unwrap_or_else(|| "?".into());
            let msg = e
                .get("msg")
                .or_else(|| e.get("desc"))
                .and_then(|m| m.as_str())
                .unwrap_or("未知错误");
            return ControlOutcome {
                accepted: false,
                request_id,
                message: Some(format!("服务端拒绝 [code={}] {}", code, msg)),
                command_id: None,
            };
        }

        // 控车成功常见形态：{"req_id":"...","data":{"command_id":N}}
        let accepted = command_id.is_some()
            || v.get("err_resp").is_none()
                && v
                    .get("code")
                    .and_then(|c| c.as_i64())
                    .map(|c| matches!(c, 0 | 1 | 200))
                    .unwrap_or(true);

        ControlOutcome {
            accepted,
            request_id,
            message: v
                .get("msg")
                .or_else(|| v.get("message"))
                .and_then(|m| m.as_str())
                .map(String::from),
            command_id,
        }
    }
}

fn now_ms() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

fn parse_json_object(text: &str) -> Result<serde_json::Value, ApiError> {
    serde_json::from_str(text).map_err(|e| format!("JSON 解析失败: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vehicle::signutil::compute_pin_hash;

    /// 四级 SHA1 的输出形状：40 位小写十六进制、同名输入稳定、换 PIN 即变。
    #[test]
    fn pin_hash_shape() {
        let a = compute_pin_hash("000000", "00000000000001", "TESTVIN0000000001", "13000000000", "zz00Z0");
        assert_eq!(a.len(), 40);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(a, a.to_lowercase());
        let b = compute_pin_hash("000001", "00000000000001", "TESTVIN0000000001", "13000000000", "zz00Z0");
        assert_ne!(a, b);
        assert_eq!(a, compute_pin_hash("000000", "00000000000001", "TESTVIN0000000001", "13000000000", "zz00Z0"));
    }

    /// 设备指纹同样是 40 位小写十六进制。
    #[test]
    fn device_id_shape() {
        let id = compute_api_device_id("0000000000000000");
        assert_eq!(id.len(), 40);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
