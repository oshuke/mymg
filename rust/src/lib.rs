//! mymg_core —— MYMG 的 Rust 核心底层。
//!
//! 职责：
//! - `vehicle::client`  HTTPS 请求车联接口（reqwest + rustls）
//! - `vehicle::model`   serde 强类型数据模型（按实际响应结构定义）
//! - `vehicle::summary` 面向 UI 的摘要与单位换算
//! - `vehicle::protocol` 协议参数（构建期注入，仓库不含真实值）
//! - `api`              暴露给 Flutter 的入口

// FRB v2 生成的绑定代码。
// 重要：这一行**不能注释**——`mod frb_generated;` 缺失会导致整个 frb_generated.rs
// 不被编译进 libmymg_core.so，所有 frb_* FFI 符号（frb_get_rust_content_hash /
// frb_pde_ffi_dispatcher_primary / frb_init_frb_dart_api_dl 等）都不会出现，
// App 启动时报 "undefined symbol 'frb_get_rust_content_hash'"。
// 位置必须在所有 `//!` 文档注释之后，否则 rustc 报 E0753。
mod frb_generated;

pub mod api;
pub mod vehicle;

pub use api::{fetch_summary, fetch_vehicle_status, parse_summary_from_json};
pub use vehicle::{MgClient, MgError, VehicleStatusResponse, VehicleSummary};

// Android logcat 桥接：把 log::info! 输出送到 adb logcat，
// 跑 `adb logcat -s mymg_core 即可看到完整请求体。
//
// 由 `MainActivity.kt` 的 companion object init 块主动 JNI 调用，
// 触发 Once 调 android_logger::init_once。
#[cfg(target_os = "android")]
use std::sync::Once;

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "C" fn Java_com_mymg_app_MainActivity_android_1main_1log_1init(
    _env: *mut std::ffi::c_void,
    _cls: *mut std::ffi::c_void,
) {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Info)
                .with_tag("mymg_core"),
        );
        log::info!("mymg_core log 通道已初始化（Java 主动调用）");
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_converts_journey_distance() {
        // 接口 current_journey_distance 单位是 0.1 km
        let raw = r#"{"req_id":"t","data":{"vehicle_value":{"current_journey_distance":6073,"fuel_level_prc":82}}}"#;
        let s = parse_summary_from_json(raw.to_string()).unwrap();
        assert_eq!(s.journey_km, Some(607.3));
        assert_eq!(s.fuel_percent, Some(82));
    }
}
