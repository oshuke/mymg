//! 请求签名工具。
//!
//! 签名算法与本仓库无关，属于通用做法：把若干片段按约定顺序拼接后做 HMAC，
//! 再转成 URL-safe Base64。参与拼接的 `app_type` 与作为密钥的应用标识
//! 都由 [`super::protocol`] 注入，仓库内不含任何真实取值。
//!
//! ```text
//! 片段  = [path, timestamp, data_json, app_type]
//! 拼接  = 排序后无分隔符连接
//! 摘要  = HMAC_SHA256(拼接, app_id)
//! 结果  = URL-safe Base64（去掉 padding）
//! ```

use super::protocol::{
    APP_ID_MG, APP_ID_ROEWE, APP_TYPE_MG, APP_TYPE_ROEWE, BODY_APP_ID_MG, BODY_APP_ID_RW,
    DEVICE_PKG,
};
use super::control::Brand;

/// 品牌 → appType（HTTP 头里的 "app-type"）
pub fn app_type_for_brand(b: Brand) -> &'static str {
    match b {
        Brand::Mg | Brand::MgLive => APP_TYPE_MG,
        Brand::Roewe => APP_TYPE_ROEWE,
    }
}

/// 品牌 → appId（同时是 sign 的 private_key）
pub fn app_id_for_brand(b: Brand) -> &'static str {
    match b {
        Brand::Mg | Brand::MgLive => APP_ID_MG,
        Brand::Roewe => APP_ID_ROEWE,
    }
}

/// SAIC 接口用的 32 字符十六进制随机串（防重放）。每次请求独立生成。
pub fn generate_nonce() -> String {
    use rand::Rng;
    const HEX: &[u8] = b"0123456789ABCDEF";
    let mut rng = rand::thread_rng();
    (0..32)
        .map(|_| HEX[rng.gen_range(0..16)] as char)
        .collect()
}

/// 计算 SAIC 接口 sign 头。
///
/// 参数顺序严格对应 `SignUtils.sign(appType, path, timestamp, data, privateKey)`：
/// 内部实现把这 5 个值中的 path/timestamp/data 先 push 到 list，
/// 再把 appType push 进去，最后 sort + 拼接 + HMAC。
pub fn compute_sign(
    app_type: &str,
    path: &str,
    timestamp: &str,
    data_json: &str,
    private_key: &str,
) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine as _};

    // 1) 构造 list：[path, timestamp, data_json, app_type]
    let mut parts = vec![path.to_string(), timestamp.to_string(), data_json.to_string()];
    parts.push(app_type.to_string());
    // 2) 升序排序
    parts.sort();
    // 3) 无分隔符拼接
    let raw = parts.join("");

    // 4) HMAC-SHA256
    let mut mac = Hmac::<Sha256>::new_from_slice(private_key.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(raw.as_bytes());
    let digest = mac.finalize().into_bytes();

    // 5) Base64 NO_WRAP（Android flag = 2）
    //    STANDARD_NO_PAD 不带 '='，等价于 Android flag=2 + 后处理去 '='
    let mut s = STANDARD_NO_PAD.encode(digest);
    // 6) URL-safe 字符替换
    s = s.replace('+', "-").replace('/', "_");
    s
}

/// SHA1 hex（小写）。PIN 链与 deviceId 都用这个。
pub fn sha1_hex(input: &str) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    h.update(input.as_bytes());
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}

/// 字符串反转（deviceId 算法用）。
pub fn reverse_str(s: &str) -> String {
    s.chars().rev().collect()
}

/// 设备指纹：`SHA1(reverse(包名) + reverse(headerDeviceId))`。
///
/// `headerDeviceId` 是请求头 `DeviceID` / `Uuid` 里的稳定设备标识；
/// 包名由 [`super::protocol::DEVICE_PKG`] 注入（未配置时用占位串，仅影响服务端风控口径）。
pub fn compute_api_device_id(header_device_id: &str) -> String {
    let pkg = if super::protocol::is_set(DEVICE_PKG) {
        DEVICE_PKG
    } else {
        "app.placeholder"
    };
    let raw = format!("{}{}", reverse_str(pkg), reverse_str(header_device_id));
    sha1_hex(&raw)
}

/// 控车 PIN 的四级 SHA1（不传明文 PIN）：
///
/// ```text
/// h1 = SHA1(pin_plain)
/// h2 = SHA1(userId + vin + h1)
/// h3 = SHA1(h2 + mobile)
/// h4 = SHA1(h3 + rav_code)   // rav_code = randomCodeWithToken 返回
/// pin = h4
/// ```
pub fn compute_pin_hash(pin_plain: &str, user_id: &str, vin: &str, mobile: &str, rav_code: &str) -> String {
    let h1 = sha1_hex(pin_plain);
    let h2 = sha1_hex(&format!("{}{}{}", user_id, vin, h1));
    let h3 = sha1_hex(&format!("{}{}", h2, mobile));
    sha1_hex(&format!("{}{}", h3, rav_code))
}

/// 请求体里的业务 appId（与签名密钥不是同一个值，由配置注入）。
pub fn body_app_id_for_brand(b: Brand) -> &'static str {
    match b {
        Brand::Mg | Brand::MgLive => BODY_APP_ID_MG,
        Brand::Roewe => BODY_APP_ID_RW,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_known_vector() {
        // 合成向量（不含任何真实凭据）：用于锁定算法行为，不涉及真实服务。
        // raw  = "/test/path" + "1700000000000" + "testapp" + "{\"a\":\"1\"}"（排序后拼接）
        let sign = compute_sign(
            "testapp",
            "/test/path",
            "1700000000000",
            r#"{"a":"1"}"#,
            "test-app-id",
        );
        assert_eq!(sign, "qIC94Fv7AWDsqvwTl25BIUoWAUxctlOOXMB_Faf3OAE");
        assert_eq!(sign.len(), 43); // 32 bytes * 4/3 ≈ 42.67 → 43 chars
    }

    #[test]
    fn nonce_format() {
        let n = generate_nonce();
        assert_eq!(n.len(), 32);
        assert!(n.chars().all(|c| matches!(c, '0'..='9'|'A'..='F')));
    }
}