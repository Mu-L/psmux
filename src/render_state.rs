//! Typed options flattened into the server-to-client render-state payload.
//! The serde renames preserve the existing short wire keys.

use crate::pane_border::PaneBorderIndicators;

#[derive(serde::Deserialize, serde::Serialize)]
pub(crate) struct ClientRenderOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_left_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_right_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "wsa_style")]
    pub window_status_activity_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "wsb_style")]
    pub window_status_bell_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "wsl_style")]
    pub window_status_last_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_active_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_border_indicators: Option<PaneBorderIndicators>,
}
