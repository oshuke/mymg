//! 面向 UI 的摘要模型：把接口的原始单位换算成人能看的单位。
//!
//! 注意换算：
//! - `current_journey_distance` 接口单位是 **0.1 km**，这里已除以 10
//! - 百分比类字段（油量）接口返回 0~100 的整数

use serde::{Deserialize, Serialize};

use crate::vehicle::model::{VehicleAlert, VehicleStatusResponse};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleSummary {
    /// 油量百分比 0~100
    pub fuel_percent: Option<i64>,
    /// 综合续航 km
    pub range_km: Option<i64>,
    /// 总里程 km
    pub odometer_km: Option<f64>,
    /// 本次行程里程 km（已由 0.1km 换算）
    pub journey_km: Option<f64>,
    /// 平均油耗 L/100km
    pub fuel_consumption: Option<f64>,
    /// 车内温度 ℃
    pub interior_temp: Option<f64>,
    /// 车外温度 ℃
    pub exterior_temp: Option<f64>,
    /// 四门锁是否全部锁闭
    pub all_locked: Option<bool>,
    /// 四门是否全部关闭
    pub all_doors_closed: Option<bool>,
    /// 车窗是否全部关闭
    pub all_windows_closed: Option<bool>,
    /// 胎压 kPa：左前 / 右前 / 左后 / 右后
    ///
    /// 注意：这里刻意用 `Vec<Option<i64>>` 而不是 `[Option<i64>; 4]`。
    /// FRB 2.13 对定长数组 `[i64; 4]` 会生成非法 Dart 类名 `PlatformInt64?Array4`
    /// （含 `?` 字符），导致 Dart 端无法编译。改用 Vec 即彻底规避该 codegen bug。
    pub tyre_kpa: Option<Vec<Option<i64>>>,
    /// 纬度
    pub latitude: Option<String>,
    /// 经度
    pub longitude: Option<String>,
    /// 数据更新时间。
    ///
    /// 注意：实测是**毫秒**级（如 1788871240000），不是秒。
    /// Dart 端用 `_parseServerTs` 做单位自适应，但别在 Rust 侧再乘 1000。
    pub update_time: Option<i64>,
    /// 车辆告警（来自 vehicle_alerts）
    pub alerts: Option<Vec<VehicleAlert>>,
    /// 空调是否开启（climate / climate_on_off_status）
    pub ac_on: Option<bool>,
    /// 空调目标温度 ℃
    pub ac_target_temp: Option<i64>,
    /// 主驾座椅加热
    pub seat_heat_driver: Option<bool>,
    /// 副驾座椅加热
    pub seat_heat_passenger: Option<bool>,
    /// 主驾座椅加热等级 0~3
    pub seat_heat_driver_level: Option<i64>,
    /// 副驾座椅加热等级 0~3
    pub seat_heat_passenger_level: Option<i64>,
}

impl VehicleSummary {
    pub fn from_response(resp: &VehicleStatusResponse) -> Self {
        let data = match resp.data.as_ref() {
            Some(d) => d,
            None => return Self::default(),
        };
        let v = data.vehicle_value.clone().unwrap_or_default();
        let s = data.vehicle_state.clone().unwrap_or_default();
        let p = data.vehicle_position.clone().unwrap_or_default();

        let all_locked = match (s.lock, s.driver_door, s.passenger_door) {
            (Some(l), Some(d), Some(pd)) => Some(l && !d && !pd),
            _ => None,
        };

        let ac_on = s
            .climate
            .or_else(|| v.climate_on_off_status.map(|x| x != 0))
            .or_else(|| v.remote_climate_status.map(|x| x != 0));
        let seat_heat_driver = s.left_seat_heat.or_else(|| {
            v.localfront_left_seat_heat_level.map(|lvl| lvl > 0)
        });
        let seat_heat_passenger = s.right_seat_heat.or_else(|| {
            v.localfront_right_seat_heat_level.map(|lvl| lvl > 0)
        });

        Self {
            fuel_percent: v.fuel_level_prc,
            range_km: v.fuel_range,
            odometer_km: v.odometer.map(|d| d as f64),
            journey_km: v
                .current_journey_distance
                .map(|d| d as f64 / 10.0),
            fuel_consumption: v.inst_fuel_consumption.map(|d| d as f64),
            interior_temp: v.interior_temperature.map(|t| t as f64),
            exterior_temp: v.exterior_temperature.map(|t| t as f64),
            all_locked,
            all_doors_closed: match (s.driver_door, s.passenger_door, s.rear_left_door, s.rear_right_door) {
                (Some(a), Some(b), Some(c), Some(d)) => Some(!a && !b && !c && !d),
                _ => None,
            },
            all_windows_closed: match (s.driver_window, s.passenger_window, s.rear_left_window, s.rear_right_window) {
                (Some(a), Some(b), Some(c), Some(d)) => Some(!a && !b && !c && !d),
                _ => None,
            },
            tyre_kpa: Some(vec![
                v.front_left_tyre_pressure,
                v.front_right_tyre_pressure,
                v.rear_left_tyre_pressure,
                v.rear_right_tyre_pressure,
            ]),
            latitude: p.latitude,
            longitude: p.longitude,
            update_time: data.update_time,
            alerts: data.vehicle_alerts.clone(),
            ac_on,
            ac_target_temp: v.target_temperature,
            seat_heat_driver,
            seat_heat_passenger,
            seat_heat_driver_level: v.localfront_left_seat_heat_level,
            seat_heat_passenger_level: v.localfront_right_seat_heat_level,
        }
    }
}
