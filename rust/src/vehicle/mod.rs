pub mod auth;
pub mod client;
pub mod control;
pub mod model;
pub mod protocol;
pub mod signutil;
pub mod summary;

pub use auth::{AuthClient, LoginResult, VehicleBrief};
pub use protocol::{BASE_HOST, BASE_URL};
pub use client::{ApiError, MgClient, MgError};
pub use control::{
    BluetoothKeyInfo, BluetoothKeysResponse, Brand, ControlClient, ControlIdentity, ControlOutcome,
    ControlStatusResult,
};
pub use model::{VehicleAlert, VehicleData, VehiclePosition, VehicleState, VehicleStatusResponse, VehicleValue};
pub use signutil::{app_id_for_brand, app_type_for_brand};
pub use protocol::is_set as protocol_is_set;
pub use summary::VehicleSummary;