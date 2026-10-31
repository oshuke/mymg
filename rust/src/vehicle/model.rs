// 由 docs/gen_rust.py 自动生成，请勿手改。
// 类型依据实测响应推断。
// 对应接口：车况读取（路径见 vehicle/protocol.rs）。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleStatusResponse {
    pub req_id: Option<String>,
    pub data: Option<VehicleData>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleData {
    #[serde(default)]
    pub vehicle_position: Option<VehiclePosition>,
    #[serde(default)]
    pub vehicle_value: Option<VehicleValue>,
    #[serde(default)]
    pub vehicle_state: Option<VehicleState>,
    #[serde(default)]
    pub vehicle_alerts: Option<Vec<VehicleAlert>>,
    /// vehicle_security 该车型恒为 null
    #[serde(default)]
    pub vehicle_security: Option<serde_json::Value>,
    #[serde(default)]
    pub update_time: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehiclePosition {
    /// 卫星数量
    #[serde(default)]
    pub satellites: Option<i64>,
    /// 海拔高度(米)
    #[serde(default)]
    pub altitude: Option<i64>,
    /// 纬度
    #[serde(default)]
    pub latitude: Option<String>,
    /// GPS状态 (2: 定位成功)
    #[serde(default)]
    pub gps_status: Option<i64>,
    /// 更新时间(毫秒时间戳)
    #[serde(default)]
    pub update_time: Option<i64>,
    /// GPS时间(毫秒时间戳)
    #[serde(default)]
    pub gps_time: Option<i64>,
    /// 水平精度因子
    #[serde(default)]
    pub hdop: Option<i64>,
    /// 经度
    #[serde(default)]
    pub longitude: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleValue {
    /// 后排右侧座椅通风等级
    #[serde(default)]
    pub local_sec_row_r_seat_vent_lvl: Option<i64>,
    /// 空调开关状态
    #[serde(default)]
    pub climate_on_off_status: Option<i64>,
    /// 方向盘加热等级
    #[serde(default)]
    pub steer_heat_level: Option<i64>,
    /// 电动尾门位置
    #[serde(default)]
    pub pwr_lftgt_pos: Option<i64>,
    /// 瞬时油耗
    #[serde(default)]
    pub inst_fuel_consumption: Option<i64>,
    /// 右后轮胎压(kPa)
    #[serde(default)]
    pub rear_right_tyre_pressure: Option<i64>,
    /// T-BOX内部电池
    #[serde(default)]
    pub tbox_internal_battery: Option<i64>,
    /// 电池包故障状态
    #[serde(default)]
    pub battery_pack_fault_status: Option<i64>,
    /// 充电门位置状态
    #[serde(default)]
    pub charge_door_position_status: Option<i64>,
    /// 电动车续航显示命令
    #[serde(default)]
    pub veh_elec_rng_dsp_cmd: Option<i64>,
    /// 后排左侧座椅通风等级
    #[serde(default)]
    pub local_sec_row_l_seat_vent_lvl: Option<i64>,
    /// BMS电池包SOC显示值
    #[serde(default)]
    pub veh_bms_pack_soc_dsp_v: Option<i64>,
    /// 电池格数
    #[serde(default)]
    pub battery_lattice_number: Option<i64>,
    /// 续航里程(km)
    #[serde(default)]
    pub driving_range: Option<i64>,
    /// 电池包续航(km)
    #[serde(default)]
    pub battery_pack_range: Option<i64>,
    /// 电源模式
    #[serde(default)]
    pub power_mode: Option<i64>,
    /// 发动机状态
    #[serde(default)]
    pub engine_status: Option<i64>,
    /// 外部温度(°C)
    #[serde(default)]
    pub exterior_temperature: Option<i64>,
    /// 后排右侧座椅加热原因
    #[serde(default)]
    pub rmt_rr_seat_heat_flr_rsn: Option<i64>,
    /// 燃油液位百分比(%)
    #[serde(default)]
    pub fuel_level_prc: Option<i64>,
    /// 前排左侧座椅加热等级
    #[serde(default)]
    pub localfront_left_seat_heat_level: Option<i64>,
    /// 车内PM2.5
    #[serde(default)]
    pub interior_pm25: Option<i64>,
    /// 里程表读数(km)
    #[serde(default)]
    pub odometer: Option<i64>,
    /// 后排左侧座椅加热等级
    #[serde(default)]
    pub local_sec_row_l_seat_heat_lvl: Option<i64>,
    /// 前排座椅加热原因
    #[serde(default)]
    pub rmt_fr_seat_heat_flr_rsn: Option<i64>,
    /// 远程座椅通风原因
    #[serde(default)]
    pub rmt_seat_vent_flr_rsn: Option<i64>,
    /// 检查状态
    #[serde(default)]
    pub inspect_status: Option<i64>,
    /// 远程方向盘加热等级
    #[serde(default)]
    pub remote_steer_heat_level: Option<i64>,
    /// 最后钥匙可见时间
    #[serde(default)]
    pub last_key_seen: Option<i64>,
    /// 轮胎胎压监测状态
    #[serde(default)]
    pub wheel_tyre_monitor_status: Option<i64>,
    /// 远程空调异常原因
    #[serde(default)]
    pub rmt_a_c_abot_rsn: Option<i64>,
    /// 车辆电池电压(V)
    #[serde(default)]
    pub vehicle_battery: Option<i64>,
    /// 车外PM2.5
    #[serde(default)]
    pub exterior_pm25: Option<i64>,
    /// 左前轮胎压(kPa)
    #[serde(default)]
    pub front_left_tyre_pressure: Option<i64>,
    /// 充电状态
    #[serde(default)]
    pub charge_status: Option<i64>,
    /// 车速(km/h)
    #[serde(default)]
    pub speed: Option<i64>,
    /// 前排右侧座椅通风等级
    #[serde(default)]
    pub localfront_right_seat_vent_level: Option<i64>,
    /// 车辆电池设备
    #[serde(default)]
    pub vehicle_battery_dev: Option<i64>,
    /// 右前轮胎压(kPa)
    #[serde(default)]
    pub front_right_tyre_pressure: Option<i64>,
    /// 电池包百分比(%)
    #[serde(default)]
    pub battery_pack_prc: Option<i64>,
    /// 车内温度显示值
    #[serde(default)]
    pub interior_temperature_v: Option<i64>,
    /// 后排右侧座椅加热等级
    #[serde(default)]
    pub local_sec_row_r_seat_heat_lvl: Option<i64>,
    /// 方向盘加热故障原因
    #[serde(default)]
    pub steer_heat_failure_reason: Option<i64>,
    /// 仪表电动车续航显示值
    #[serde(default)]
    pub clstr_elec_rng_to_eptv: Option<i64>,
    /// 燃油续航(km)
    #[serde(default)]
    pub fuel_range: Option<i64>,
    /// 当前行程ID
    #[serde(default)]
    pub current_journey_id: Option<i64>,
    /// 电动尾门位置显示值
    #[serde(default)]
    pub pwr_lftgt_pos_v: Option<i64>,
    /// 车内温度(°C)
    #[serde(default)]
    pub interior_temperature: Option<i64>,
    /// 前排右侧座椅加热等级
    #[serde(default)]
    pub localfront_right_seat_heat_level: Option<i64>,
    /// 航向角
    #[serde(default)]
    pub heading: Option<i64>,
    /// 电池报警值数组
    #[serde(default)]
    pub battery_alarm_value: Option<Vec<serde_json::Value>>,
    /// 更新时间(毫秒时间戳)
    #[serde(default)]
    pub update_time: Option<i64>,
    /// 远程空调状态
    #[serde(default)]
    pub remote_climate_status: Option<i64>,
    /// FOTA状态
    #[serde(default)]
    pub fota_status: Option<i64>,
    /// 当前行程距离(km)
    #[serde(default)]
    pub current_journey_distance: Option<i64>,
    /// BMS充电状态
    #[serde(default)]
    pub bms_charge_status: Option<i64>,
    /// 车辆报警状态
    #[serde(default)]
    pub vehicle_alarm_status: Option<i64>,
    /// 左后轮胎压(kPa)
    #[serde(default)]
    pub rear_left_tyre_pressure: Option<i64>,
    /// 车辆智能场景模式
    #[serde(default)]
    pub veh_intlgnt_scene_md: Option<i64>,
    /// 车辆电池百分比(%)
    #[serde(default)]
    pub vehicle_battery_prc: Option<i64>,
    /// 电池类型
    #[serde(default)]
    pub battery_type: Option<i64>,
    /// 燃油液位显示
    #[serde(default)]
    pub fuel_level_disp: Option<i64>,
    /// 监测状态
    #[serde(default)]
    pub monitor_status: Option<i64>,
    /// 充电剩余时间显示值
    #[serde(default)]
    pub chrgng_rmnng_time: Option<i64>,
    /// 前排左侧座椅通风等级
    #[serde(default)]
    pub localfront_left_seat_vent_level: Option<i64>,
    #[serde(default)]
    pub chrgng_rmnng_time_v: Option<serde_json::Value>,
    #[serde(default)]
    pub target_temperature: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleState {
    /// 车门状态(任意车门)
    #[serde(default)]
    pub door: Option<bool>,
    /// GPS天线连接状态
    #[serde(default)]
    pub gnss_ant_connected: Option<bool>,
    /// 后排左侧座椅加热
    #[serde(default)]
    pub second_row_left_seat_heat: Option<bool>,
    /// 右后车门状态
    #[serde(default)]
    pub rear_right_door: Option<bool>,
    /// 近光灯状态
    #[serde(default)]
    pub dipped_beam: Option<bool>,
    /// 后排右侧座椅通风
    #[serde(default)]
    pub second_row_right_seat_vent: Option<bool>,
    /// 驾驶员车窗状态
    #[serde(default)]
    pub driver_window: Option<bool>,
    /// 车辆电池连接状态
    #[serde(default)]
    pub vehicle_battery_connected: Option<bool>,
    /// 仪表续航显示
    #[serde(default)]
    pub clstr_range: Option<bool>,
    /// 驾驶员车门状态
    #[serde(default)]
    pub driver_door: Option<bool>,
    /// 座椅加热状态
    #[serde(default)]
    pub seat_heat: Option<bool>,
    /// 车门锁定状态
    #[serde(default)]
    pub lock: Option<bool>,
    /// 右侧座椅加热
    #[serde(default)]
    pub right_seat_heat: Option<bool>,
    /// 反馈状态
    #[serde(default)]
    pub feed: Option<bool>,
    /// 喇叭状态
    #[serde(default)]
    pub horn: Option<bool>,
    /// 空气净化状态
    #[serde(default)]
    pub air_clean: Option<bool>,
    /// 大灯状态
    #[serde(default)]
    pub light: Option<bool>,
    /// 前引擎盖状态
    #[serde(default)]
    pub bonnet: Option<bool>,
    /// 电池低压状态
    #[serde(default)]
    pub bat_low: Option<bool>,
    /// 检查状态
    #[serde(default)]
    pub inspect: Option<bool>,
    /// 方向盘加热状态
    #[serde(default)]
    pub steer_heat: Option<bool>,
    /// 示宽灯状态
    #[serde(default)]
    pub side_light: Option<bool>,
    /// GSM天线连接状态
    #[serde(default)]
    pub gsm_ant_connected: Option<bool>,
    /// 后排左侧座椅通风
    #[serde(default)]
    pub second_row_left_seat_vent: Option<bool>,
    /// 电池包状态
    #[serde(default)]
    pub battery_pack: Option<bool>,
    /// 组合控制状态
    #[serde(default)]
    pub combination_control: Option<bool>,
    /// 发动机状态
    #[serde(default)]
    pub engine: Option<bool>,
    /// 座椅通风状态
    #[serde(default)]
    pub seat_vent: Option<bool>,
    /// 后排右侧座椅加热
    #[serde(default)]
    pub second_row_right_seat_heat: Option<bool>,
    /// 左侧座椅通风
    #[serde(default)]
    pub left_seat_vent: Option<bool>,
    /// 电源状态
    #[serde(default)]
    pub power: Option<bool>,
    /// 后备箱状态
    #[serde(default)]
    pub boot: Option<bool>,
    /// 电源保护状态
    #[serde(default)]
    pub power_protection: Option<bool>,
    /// 充电状态
    #[serde(default)]
    pub charge: Option<bool>,
    /// 副驾驶车门状态
    #[serde(default)]
    pub passenger_door: Option<bool>,
    /// CAN总线状态
    #[serde(default)]
    pub can_bus: Option<bool>,
    /// 更新时间(毫秒时间戳)
    #[serde(default)]
    pub update_time: Option<i64>,
    /// 监测状态
    #[serde(default)]
    pub monitor: Option<bool>,
    /// 空调状态
    #[serde(default)]
    pub climate: Option<bool>,
    /// 右侧座椅通风
    #[serde(default)]
    pub right_seat_vent: Option<bool>,
    /// 左侧座椅加热
    #[serde(default)]
    pub left_seat_heat: Option<bool>,
    /// 右后车窗状态
    #[serde(default)]
    pub rear_right_window: Option<bool>,
    /// 天窗状态
    #[serde(default)]
    pub sunroof: Option<bool>,
    /// 左后车门状态
    #[serde(default)]
    pub rear_left_door: Option<bool>,
    /// 副驾驶车窗状态
    #[serde(default)]
    pub passenger_window: Option<bool>,
    /// 车窗状态(任意车窗)
    #[serde(default)]
    pub window: Option<bool>,
    /// 左后车窗状态
    #[serde(default)]
    pub rear_left_window: Option<bool>,
    /// 远光灯状态
    #[serde(default)]
    pub main_beam: Option<bool>,
}

/// 车辆告警项
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VehicleAlert {
    #[serde(default)]
    pub alert_type: Option<i64>,
    #[serde(default)]
    pub alert_id: Option<i64>,
    #[serde(default)]
    pub alert_data: Option<i64>,
    #[serde(default)]
    pub alert_time: Option<i64>,
}
