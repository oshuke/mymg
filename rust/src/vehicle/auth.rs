//! 账号登录（手机号 + 短信验证码）。
//!
//! 链路：发验证码 → 验证码登录 → 取绑定车辆列表 → 换取业务令牌 → 拉用户信息。
//! 登录类请求走 `uais` / `user` 两组路径，POST `data={json}`，并带签名头。
//!
//! 所有主机、路径、站点标识与版本号都由 [`super::protocol`] 注入，
//! 仓库内不含任何真实取值。未配置时，App 仍可用「手动填入访问令牌 + VIN」
//! 的路径查看车况（见 `login_page.dart` 的手动入口）。

use super::client::ApiError;
use super::protocol::{
    APP_CODE, APP_ID_MG, APP_TYPE_MG, APP_VERSION, BASE_HOST, BRAND_CODE, LOGIN_HOST,
    PATH_LOGIN, PATH_OUTSIDE_TOKEN, PATH_SEND_SMS, PATH_USER_INFO, PATH_VEHICLE_LIST,
};
use super::signutil::compute_sign;

// ──────────────────────────────────────────────────────────────
// 登录链路默认身份（换品牌时改这两行）
// ──────────────────────────────────────────────────────────────
const LOGIN_APP_TYPE: &str = APP_TYPE_MG;
const LOGIN_APP_ID: &str = APP_ID_MG;

fn login_url(path: &str) -> String {
    format!("https://{}{}", LOGIN_HOST, path)
}

fn status_url(path: &str) -> String {
    format!("https://{}{}", BASE_HOST, path)
}

/// 登录成功后拿到的凭证
#[derive(Debug, Clone)]
pub struct LoginResult {
    /// 访问令牌，车况接口要用
    pub token: String,
    pub user_id: Option<String>,
    pub phone: Option<String>,
}

/// 车辆列表里的一项（用户可能有好几辆车）
#[derive(Debug, Clone)]
pub struct VehicleBrief {
    pub vin: String,
    pub model: Option<String>,
    pub plate: Option<String>,
}

pub struct AuthClient {
    http: reqwest::Client,
}

impl Default for AuthClient {
    fn default() -> Self {
        Self::new().expect("创建 AuthClient 失败")
    }
}

impl AuthClient {
    pub fn new() -> Result<Self, ApiError> {
        super::protocol::ensure_configured()?;
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .user_agent("okhttp/4.9.3")
            .build()
            .map_err(|e| format!("创建 reqwest Client 失败: {}", e))?;
        Ok(Self { http })
    }

    /// 请求手机号对应的短信验证码。
    ///
    /// 前置：WebView 易盾滑块拿到 `NECaptchaValidate` + `captchaId`。
    /// [device_id] 与登录请求保持一致（android_id / 头 Uuid）。
    pub async fn send_sms_code_with_captcha(
        &self,
        phone: &str,
        captcha_id: &str,
        captcha_validate: &str,
    ) -> Result<(), ApiError> {
        self.send_sms_code_full(phone, captcha_id, captcha_validate, "mymg000000000001")
            .await
    }

    pub async fn send_sms_code_full(
        &self,
        phone: &str,
        captcha_id: &str,
        captcha_validate: &str,
        device_id: &str,
    ) -> Result<(), ApiError> {
        if !is_valid_phone(phone) {
            return Err("手机号必须是 11 位中国大陆号码".to_string());
        }
        if captcha_validate.trim().is_empty() {
            return Err("请先完成滑块验证（NECaptchaValidate 为空）".to_string());
        }

        let api_device = crate::vehicle::signutil::compute_api_device_id(device_id);
        let data = serde_json::json!({
            "NECaptchaValidate": captcha_validate,
            "captchaId": captcha_id,
            "brandCode": BRAND_CODE,
            "mobilePhone": phone,
            "deviceId": api_device,
            "uuid": device_id,
            "appType": APP_CODE,
            "app_version": APP_VERSION,
            "platformType": "android",
        });

        log::info!("POST {} data={}", PATH_SEND_SMS, data);
        let body = self.post_to(LOGIN_HOST, PATH_SEND_SMS, &data, None, device_id).await?;
        log::info!("RESP body={}", body);
        check_biz_error(&body)?;
        // 官方成功样例：{"data":{"send":"true"}}
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
            let send = v
                .pointer("/data/send")
                .and_then(|x| x.as_str())
                .map(|s| s.eq_ignore_ascii_case("true"))
                .unwrap_or(true);
            if !send {
                return Err("服务端未真正发送短信（send=false），可能手机号格式/加密或风控问题".into());
            }
        }
        Ok(())
    }

    /// 登录成功后换取车况/控车侧 token。
    /// 用登录令牌换业务侧令牌。
    /// 请求体形如 `{"brandCode":…,"deviceId":"","token":…,"types":[1]}`；
    /// 响应里取 `data.swapToken`（可能与登录令牌相同，也可能不同）。
    pub async fn get_outside_token(
        &self,
        login_token: &str,
        user_id: Option<&str>,
        device_id: &str,
    ) -> Result<String, ApiError> {
        let mut data = serde_json::json!({
            "appId": APP_CODE,
            "brandCode": BRAND_CODE,
            "token": login_token,
            // 官方固定：请求类型 1（服务端/车控侧 swap）
            "types": [1],
        });
        if let Some(uid) = user_id {
            if !uid.is_empty() {
                data["userId"] = serde_json::json!(uid);
            }
        }
        log::info!("POST {} data={}", PATH_OUTSIDE_TOKEN, data);
        let body = self
            .post_to(LOGIN_HOST, PATH_OUTSIDE_TOKEN, &data, Some(login_token), device_id)
            .await?;
        log::info!("RESP body={}", body);
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
            // 优先 swapToken（官方响应字段）
            let swap = v
                .pointer("/data/swapToken")
                .or_else(|| v.pointer("/swapToken"))
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty());
            if let Some(t) = swap {
                return Ok(t.to_string());
            }
            if let Some(t) = find_token(&v) {
                if super::protocol::is_set(&t) {
                    return Ok(t);
                }
            }
        }
        // 没拿到 swapToken 时保留原 token
        Ok(login_token.to_string())
    }

    /// 兼容旧调用
    pub async fn send_sms_code(&self, phone: &str) -> Result<(), ApiError> {
        self.send_sms_code_with_captcha(phone, "", "").await
    }

    /// 用短信验证码登录，成功返回 token。
    pub async fn login_by_sms(&self, phone: &str, code: &str) -> Result<LoginResult, ApiError> {
        self.login_by_sms_device(phone, code, "mymg000000000001").await
    }

    pub async fn login_by_sms_device(
        &self,
        phone: &str,
        code: &str,
        device_id: &str,
    ) -> Result<LoginResult, ApiError> {
        if !is_valid_phone(phone) {
            return Err("手机号必须是 11 位中国大陆号码".to_string());
        }
        if code.trim().is_empty() {
            return Err("验证码不能为空".to_string());
        }

        let api_device = crate::vehicle::signutil::compute_api_device_id(device_id);
        let data = serde_json::json!({
            "app_version": APP_VERSION,
            "mobile_type": super::protocol::mobile_type(),
            "os_version": "34",
            "platformType": "android",
            "mobile_brand": super::protocol::mobile_brand(),
            "uuid": device_id,
            "deviceId": api_device,
            "vcode": code.trim(),
            "sid": "",
            "phone": phone,
            "appType": APP_CODE,
            "phoneName": "",
            "brandCode": BRAND_CODE,
        });

        log::info!("POST {} data={}", PATH_LOGIN, data);
        let body = self
            .post_to(LOGIN_HOST, PATH_LOGIN, &data, None, device_id)
            .await?;
        log::info!("RESP body={}", body);

        let v: serde_json::Value =
            serde_json::from_str(&body).map_err(|e| format!("JSON 解析失败: {}", e))?;

        // 先找 token：有 token 就算业务成功，避免 14101 假阴性
        let token = find_token(&v);
        if token.is_none() {
            check_biz_error(&body)?;
            return Err("登录响应里没找到 token".to_string());
        }
        let token = token.unwrap();

        let data_node = v.get("data");
        let ld = data_node.and_then(|d| d.get("loginData"));
        Ok(LoginResult {
            token,
            user_id: find_str(ld.unwrap_or(data_node.unwrap_or(&v)), &["user_id", "userId", "uid"]),
            phone: Some(phone.to_string()),
        })
    }

    /// 用 token 拉用户信息，补全 userId（login 里 user_id 可能是数字）
    pub async fn fetch_user_id(
        &self,
        token: &str,
        device_id: &str,
    ) -> Result<Option<String>, ApiError> {
        let data = serde_json::json!({
            "appId": APP_CODE,
            "brandCode": BRAND_CODE,
            "token": token,
        });
        log::info!("POST {} data={}", PATH_USER_INFO, data);
        let body = self
            .post_to(LOGIN_HOST, PATH_USER_INFO, &data, Some(token), device_id)
            .await?;
        log::info!("RESP body={}", body);
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) else {
            return Ok(None);
        };
        // 多层探测：data.uid / data.userId / data.user_id / data.user.uid
        let data = v.get("data");
        for node in [
            data,
            data.and_then(|d| d.get("user")),
            data.and_then(|d| d.get("userInfo")),
            data.and_then(|d| d.get("loginData")),
        ]
        .into_iter()
        .flatten()
        {
            if let Some(s) = find_str(node, &["uid", "user_id", "userId"]) {
                return Ok(Some(s));
            }
        }
        Ok(None)
    }

    /// 拉取账号下的绑定车辆列表，用来自动拿到 VIN。
    pub async fn fetch_vins(&self, token: &str) -> Result<Vec<VehicleBrief>, ApiError> {
        self.fetch_vins_user(token, None).await
    }

    pub async fn fetch_vins_user(
        &self,
        token: &str,
        user_id: Option<&str>,
    ) -> Result<Vec<VehicleBrief>, ApiError> {
        let mut base_data = serde_json::json!({
            "appId": APP_CODE,
            "brandCode": BRAND_CODE,
            "token": token,
        });
        if let Some(uid) = user_id {
            if !uid.is_empty() {
                base_data["userId"] = serde_json::json!(uid);
            }
        }

        let mut last = String::new();
        for base in [BASE_HOST, LOGIN_HOST] {
            log::info!("POST {} data={}", PATH_VEHICLE_LIST, base_data);
            match self
                .post_to(base, PATH_VEHICLE_LIST, &base_data, Some(token), "mymg000000000001")
                .await
            {
                Ok(body) => {
                    log::info!("RESP {} body={}", base, body);
                    if let Err(e) = check_biz_error(&body) {
                        last = format!("[{}] {}", base, e);
                        continue;
                    }
                    let v: serde_json::Value = serde_json::from_str(&body)
                        .map_err(|e| format!("JSON 解析失败: {}", e))?;
                    return Ok(parse_vehicles(&v));
                }
                Err(e) => {
                    last = format!("[{}] {}", base, e);
                }
            }
        }
        Err(format!(
            "取 VIN 失败：{}。登录 token 已保存，可手动补填 VIN。",
            last
        ))
    }

    /// 统一的登录类 POST：`application/x-www-form-urlencoded` 的 `data={json}`
    /// + `app-type` / `timestamp` / `sign` 头。
    async fn post_data(&self, path: &str, data: &serde_json::Value) -> Result<String, ApiError> {
        self.post_to(LOGIN_HOST, path, data, None, "mymg000000000001")
            .await
    }

    async fn post_to(
        &self,
        host: &str,
        path: &str,
        data: &serde_json::Value,
        token: Option<&str>,
        device_id: &str,
    ) -> Result<String, ApiError> {
        let ts = now_ms();
        let body_str = data.to_string();
        let sign = compute_sign(LOGIN_APP_TYPE, path, &ts, &body_str, LOGIN_APP_ID);

        let mut req = self
            .http
            .post(format!("https://{}{}", host, path))
            .header("app-type", LOGIN_APP_TYPE)
            .header("timestamp", ts)
            .header("sign", sign)
            .header("brandCode", BRAND_CODE)
            .header("versionCode", "146")
            .header("channelID", APP_CODE)
            .header("x-client-id", "APP")
            .header("x-saic-security-version", "v1")
            .header("Model", "ehs")
            .header("os", "android")
            .header("osVersion", "34")
            .header("Uuid", device_id)
            .header("DeviceID", device_id)
            .header("User-Agent", "okhttp/4.9.1");
        if let Some(t) = token {
            req = req.header("token", t);
        }
        let resp = req
            .form(&[("data", body_str.as_str())])
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {}", e))?;

        resp.text().await.map_err(|e| format!("读取响应失败: {}", e))
    }
}

// ── 工具函数 ──────────────────────────────────────────────────

pub fn is_valid_phone(p: &str) -> bool {
    let p = p.trim();
    p.len() == 11 && p.starts_with('1') && p.chars().all(|c| c.is_ascii_digit())
}

/// 业务码检查。认不出返回码字段时直接放行，避免误杀。
fn check_biz_error(body: &str) -> Result<(), ApiError> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return Ok(());
    };

    // ⚠️ 上汽/斑马接口的错误统一放在 `err_resp` 里（顶层没有 code）：
    //    {"req_id":"...","err_resp":{"msg":"...","code":"14101","desc":"..."}}
    // 不检查这里会把「登录态失效」「用户无操作权限」误判成成功。
    if let Some(e) = v.get("err_resp") {
        let code = e
            .get("code")
            .and_then(|c| c.as_str())
            .map(|s| s.to_string())
            .or_else(|| e.get("code").and_then(|c| c.as_i64()).map(|n| n.to_string()))
            .unwrap_or_else(|| "?".to_string());
        let msg = e
            .get("msg")
            .or_else(|| e.get("desc"))
            .and_then(|m| m.as_str())
            .unwrap_or("未知错误");
        return Err(format!("服务端拒绝 [code={}] {}", code, msg));
    }

    // 常见的成功码（少数接口把 code 放顶层）
    let code = v
        .get("code")
        .or_else(|| v.get("ret"))
        .or_else(|| v.get("status"))
        .and_then(|c| c.as_i64());

    if let Some(c) = code {
        // 0 / 200 / 1 都当作成功（各接口约定不一）
        if matches!(c, 0 | 200 | 1) {
            return Ok(());
        }
        let msg = v
            .get("msg")
            .or_else(|| v.get("message"))
            .or_else(|| v.get("errmsg"))
            .and_then(|m| m.as_str())
            .unwrap_or("未知错误");
        return Err(format!("接口返回错误 {}: {}", c, msg));
    }
    Ok(())
}

/// 在响应的若干常见位置里找 token。
/// 登录接口实际结构：`data.loginData.token`。
fn find_token(v: &serde_json::Value) -> Option<String> {
    let keys = ["token", "accessToken", "access_token", "ACCESS_TOKEN"];
    if let Some(s) = find_str(v, &keys) {
        return Some(s);
    }
    if let Some(d) = v.get("data") {
        if let Some(s) = find_str(d, &keys) {
            return Some(s);
        }
        // 再深一层：data.loginData.token / data.userInfo.token / data.user.token
        if let Some(u) = d
            .get("loginData")
            .or_else(|| d.get("userInfo"))
            .or_else(|| d.get("user"))
        {
            if let Some(s) = find_str(u, &keys) {
                return Some(s);
            }
        }
        // 再深一层：data.logindata.token（有的日志小写 d）
        if let Some(u) = d.get("logindata") {
            if let Some(s) = find_str(u, &keys) {
                return Some(s);
            }
        }
    }
    None
}

fn find_str(v: &serde_json::Value, keys: &[&str]) -> Option<String> {
    for k in keys {
        let Some(val) = v.get(*k) else {
            continue;
        };
        if let Some(s) = val.as_str() {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
        // 官方 user_id 是数字（如 10000004425431），一并接受
        if let Some(n) = val.as_i64() {
            return Some(n.to_string());
        }
        if let Some(n) = val.as_u64() {
            return Some(n.to_string());
        }
    }
    None
}

fn parse_vehicles(v: &serde_json::Value) -> Vec<VehicleBrief> {
    // 实际结构：data.bound_vin_list_roewe[]（名爵）或 data.bound_vin_list[]（通用）
    let mut arr = v
        .get("data")
        .and_then(|d| d.get("bound_vin_list_roewe"))
        .and_then(|l| l.as_array())
        .map(|a| a.clone());

    if arr.is_none() {
        arr = v
            .get("data")
            .and_then(|d| d.get("bound_vin_list"))
            .and_then(|l| l.as_array())
            .map(|a| a.clone());
    }

    let Some(arr) = arr else {
        return Vec::new();
    };

    arr.iter()
        .filter_map(|it| {
            let vin = find_str(it, &["vin", "VIN", "vinCode"])?;
            Some(VehicleBrief {
                vin,
                model: find_str(it, &["modelName", "model", "seriesName", "series_name"]),
                plate: find_str(it, &["plateNo", "plate", "license", "vehicle_no"]),
            })
        })
        .collect()
}

/// 当前毫秒时间戳（登录类接口用毫秒，13 位）。
fn now_ms() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".to_string())
}
