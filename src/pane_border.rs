//! Policy for marking the active pane at tiled and floating pane borders.
//!
//! Line glyph selection remains in `border_lines`; this module owns whether
//! active-pane colour cues, arrow cues, both, or neither are drawn.

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneBorderIndicators {
    Off,
    #[default]
    Colour,
    Arrows,
    Both,
}

impl PaneBorderIndicators {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Colour => "colour",
            Self::Arrows => "arrows",
            Self::Both => "both",
        }
    }

    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "off" => Ok(Self::Off),
            "colour" => Ok(Self::Colour),
            "arrows" => Ok(Self::Arrows),
            "both" => Ok(Self::Both),
            _ => Err(format!(
                "invalid value '{}' for pane-border-indicators (expected off, colour, arrows, or both)",
                value,
            )),
        }
    }

    pub(crate) fn uses_colour(self) -> bool {
        matches!(self, Self::Colour | Self::Both)
    }

    pub(crate) fn uses_arrows(self) -> bool {
        matches!(self, Self::Arrows | Self::Both)
    }
}

pub const INDICATORS_DEFAULT: &str = PaneBorderIndicators::Colour.as_str();
