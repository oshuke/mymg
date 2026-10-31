//! 车况接口客户端。
//!
//! 车况查询是一条只读 GET：三个 query 参数（时间戳 / 访问令牌 / VIN）。
//! 主机与路径由 [`super::protocol`] 注入，仓库内不含真实地址。
//!
//! ```text
//! GET <MYMG_STATUS_URL>?timestamp=<秒级时间戳>&token=<访问令牌>&vin=<17 位 VIN>
//! ```

use std::time::{SystemTime, UNIX_EPOCH};

use crate::vehicle::model::VehicleStatusResponse;

pub use super::protocol::{BASE_HOST, BASE_URL, LOGIN_HOST};

/// 业务错误。
///
/// 之前是 `enum MgError`，FRB codegen 会把它生成为 Dart 端的
/// `abstract class MgError implements RustOpaqueInterface`，
/// catch 后只显示 `Instance of MgErrorImpl`，丢失详细消息。
///
/// 现在改为**单 String 变体**的 newtype，FRB 会自动转成 Dart `String`，
/// catch 后直接显示完整错误（业务码 + 描述）。内部模块继续用 `MgError` enum
/// 自由组合，最终在 `api.rs` 层用 `?` + `From<MgError> for ApiError` 转 String。
#[derive(Debug, thiserror::Error)]
pub enum MgError {
    #[error("网络请求失败: {0}")]
    Http(String),
    #[error("JSON 解析失败: {0}")]
    Json(String),
    #[error("参数错误: {0}")]
    Invalid(&'static str),
    /// 运行期拼出来的错误消息（比如接口返回的业务错误码）
    #[error("{0}")]
    Other(String),
}

/// `api.rs` 暴露给 Flutter 的错误类型。永远是 String，Dart 端能直接显示。
pub type ApiError = String;

impl From<MgError> for ApiError {
    fn from(e: MgError) -> Self {
        e.to_string()
    }
}

/// 接口客户端。内部复用同一个连接池。
pub struct MgClient {
    http: reqwest::Client,
}

impl Default for MgClient {
    fn default() -> Self {
        Self::new().expect("创建 reqwest 客户端失败")
    }
}

impl MgClient {
    pub fn new() -> Result<Self, MgError> {
        super::protocol::ensure_configured().map_err(MgError::Other)?;
        let http = super::control::shared_http().clone();
        Ok(Self { http })
    }

    /// 拉取车辆状态全量字段。
    ///
    /// 多路径兜底（不同版本的服务端可能只提供其中一部分）：
    /// 1) GET 1.1 主域名
    /// 2) GET 1.1 备用域名
    /// 3) POST 1.2 主域名
    /// 4) POST 1.2 备用域名
    pub async fn get_vehicle_status(
        &self,
        token: &str,
        vin: &str,
    ) -> Result<VehicleStatusResponse, MgError> {
        if vin.len() != 17 {
            return Err(MgError::Invalid("VIN 必须是 17 位"));
        }
        if token.trim().is_empty() {
            return Err(MgError::Invalid("token 不能为空"));
        }

        let mut errors: Vec<String> = Vec::new();

        // 主动上报只打主域名（并行双域会触发服务端限频）。
        // 成功：车上报需时间，等 400ms 后读；仍偏旧则再等 600ms 补读一轮。
        // 失败：不吞错，记日志后直接读服务端缓存（至少有旧数据）。
        let woke = self.request_vehicle_status_on(BASE_HOST, token, vin).await.is_ok();
        if woke {
            eprintln!("[MYMG] requestVehicleStatus ok");
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        } else {
            eprintln!("[MYMG] requestVehicleStatus fail, read server cache");
        }

        // 手动刷新优先走 POST 读缓存接口
        for attempt in 0..2u8 {
            if attempt > 0 {
                // 唤醒后补读：给休眠车更多上报时间
                tokio::time::sleep(std::time::Duration::from_millis(if woke { 600 } else { 400 })).await;
            }
            for (label, host) in [
                ("primary", BASE_HOST),
                ("secondary", LOGIN_HOST),
            ] {
                match self.post_status_v12_on(host, token, vin).await {
                    Ok(r) => return Ok(r),
                    Err(e) => errors.push(format!("POST 1.2@{}: {}", label, e)),
                }
            }
            for (label, host) in [
                ("primary", BASE_HOST),
                ("secondary", LOGIN_HOST),
            ] {
                match self.get_status_v11_on(host, token, vin).await {
                    Ok(r) => return Ok(r),
                    Err(_) => errors.push(format!("GET 1.1@{}", label)),
                }
            }
        }

        Err(MgError::Other(format!(
            "拉取车况失败（{}）。访问令牌可能无效或已过期：请重新登录获取令牌，或手动填写新的令牌。",
            errors.join("；")
        )))
    }

    async fn get_status_v11_on(
        &self,
        host: &str,
        token: &str,
        vin: &str,
    ) -> Result<VehicleStatusResponse, MgError> {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let resp = self
            .http
            .get(format!("https://{}{}", host, super::protocol::PATH_STATUS_V11))
            .query(&[
                ("timestamp", ts.to_string()),
                ("token", token.to_string()),
                ("vin", vin.to_string()),
            ])
            .header("User-Agent", "okhttp/4.9.1")
            .send()
            .await
            .map_err(|e| MgError::Http(e.to_string()))?;

        let status = resp.status();
        let body = resp.text().await.map_err(|e| MgError::Http(e.to_string()))?;
        if !status.is_success() {
            return Err(MgError::Invalid("GET 1.1 非 2xx"));
        }
        check_err_resp(&body)?;
        Ok(serde_json::from_str(&body).map_err(|e| MgError::Json(e.to_string()))?)
    }

    /// 请车辆主动上报一次（下拉刷新的第一步）
    pub async fn request_vehicle_status_on(
        &self,
        host: &str,
        token: &str,
        vin: &str,
    ) -> Result<(), MgError> {
        use crate::vehicle::control::Brand;
        use crate::vehicle::signutil::{
            app_id_for_brand, app_type_for_brand, body_app_id_for_brand, compute_sign,
            generate_nonce,
        };

        let brand = Brand::MgLive;
        let path = super::protocol::PATH_STATUS_REQUEST;
        let header_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
            .to_string();
        let nonce = generate_nonce();
        let app_type = app_type_for_brand(brand);
        let sign_key = app_id_for_brand(brand);
        let body_app = body_app_id_for_brand(brand);

        let mut data = serde_json::Map::new();
        data.insert("appId".into(), serde_json::json!(body_app));
        data.insert("vin".into(), serde_json::json!(vin));
        data.insert("nonce".into(), serde_json::json!(nonce));
        data.insert("brandCode".into(), serde_json::json!(brand.code()));
        data.insert("timestamp".into(), serde_json::json!(header_ts));
        data.insert("token".into(), serde_json::json!(token));
        let data_str = serde_json::to_string(&serde_json::Value::Object(data))
            .map_err(|e| MgError::Json(e.to_string()))?;
        let sign = compute_sign(app_type, path, &header_ts, &data_str, sign_key);

        let resp = self
            .http
            .post(format!("https://{}{}", host, path))
            .header("Uuid", "mymg000000000001")
            .header("DeviceID", "mymg000000000001")
            .header("os", "android")
            .header("osVersion", "34")
            .header("x-client-id", "APP")
            .header("versionCode", "146")
            .header("token", token)
            .header("brandCode", brand.code())
            .header("timestamp", &header_ts)
            .header("app-type", app_type)
            .header("sign", &sign)
            .header("User-Agent", "okhttp/4.9.1")
            .form(&[("data", data_str.as_str())])
            .send()
            .await
            .map_err(|e| MgError::Http(e.to_string()))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| MgError::Http(e.to_string()))?;
        if !status.is_success() {
            return Err(MgError::Other(format!(
                "requestVehicleStatus HTTP {}",
                status
            )));
        }
        // 业务错误也要暴露：限频 / 登录态失效会让车辆根本没被叫醒
        check_err_resp(&body)?;
        Ok(())
    }

    async fn post_status_v12_on(
        &self,
        host: &str,
        token: &str,
        vin: &str,
    ) -> Result<VehicleStatusResponse, MgError> {
        use crate::vehicle::control::Brand;
        use crate::vehicle::signutil::{
            app_id_for_brand, app_type_for_brand, body_app_id_for_brand, compute_sign,
            generate_nonce,
        };

        let brand = Brand::MgLive;
        let path = super::protocol::PATH_STATUS_V12;
        let header_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
            .to_string();
        let nonce = generate_nonce();
        let app_type = app_type_for_brand(brand);
        let sign_key = app_id_for_brand(brand);
        let body_app = body_app_id_for_brand(brand);

        let mut data = serde_json::Map::new();
        data.insert("appId".into(), serde_json::json!(body_app));
        data.insert("vin".into(), serde_json::json!(vin));
        data.insert("nonce".into(), serde_json::json!(nonce));
        data.insert("brandCode".into(), serde_json::json!(brand.code()));
        data.insert("timestamp".into(), serde_json::json!(header_ts));
        data.insert("token".into(), serde_json::json!(token));
        let data_str = serde_json::to_string(&serde_json::Value::Object(data))
            .map_err(|e| MgError::Json(e.to_string()))?;
        let sign = compute_sign(app_type, path, &header_ts, &data_str, sign_key);

        let resp = self
            .http
            .post(format!("https://{}{}", host, path))
            .header("Uuid", "mymg000000000001")
            .header("DeviceID", "mymg000000000001")
            .header("os", "android")
            .header("osVersion", "34")
            .header("x-client-id", "APP")
            .header("versionCode", "146")
            .header("token", token)
            .header("brandCode", brand.code())
            .header("timestamp", &header_ts)
            .header("app-type", app_type)
            .header("sign", &sign)
            .header("User-Agent", "okhttp/4.9.1")
            .form(&[("data", data_str.as_str())])
            .send()
            .await
            .map_err(|e| MgError::Http(e.to_string()))?;

        let body = resp.text().await.map_err(|e| MgError::Http(e.to_string()))?;
        check_err_resp(&body)?;
        Ok(serde_json::from_str(&body).map_err(|e| MgError::Json(e.to_string()))?)
    }
}

fn check_err_resp(body: &str) -> Result<(), MgError> {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
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
            return Err(MgError::Other(format!("服务端拒绝 [code={}] {}", code, msg)));
        }
    }
    Ok(())
}
