// Option default parity.
//
// Contract: for every option in OPTION_CATALOG, the `default` string the catalog
// advertises must be the value a freshly constructed AppState actually reports.
//
// This matters because the catalog `default` field is not decorative. It is what
// customize-mode restores when the user resets an option (`d` in customize-mode,
// wire command `customize-reset-default`). If the catalog disagrees with the
// runtime initializer, resetting an option silently changes a value the user
// never touched, and `customize-mode` displays a default that is a lie.
//
// Claim under test: `status-right` diverges.

use super::*;
use crate::server::option_catalog::{default_for, OPTION_CATALOG};
use crate::server::options::get_option_value;

fn fresh_app() -> crate::types::AppState {
    crate::types::AppState::new("parity_probe".to_string())
}

/// Options whose catalog default legitimately cannot be compared verbatim against
/// a fresh AppState. Each entry needs a reason. This list is deliberately tiny;
/// anything added here is an admission that the option has no single truthful
/// default, so justify it or fix the option instead.
fn exempt(name: &str) -> Option<&'static str> {
    match name {
        // Resolved at read time to the first shell that exists on this machine
        // (pwsh, then powershell, then cmd), so it is host dependent by design.
        "default-shell" => Some("host dependent shell resolution"),
        "default-command" => Some("alias of default-shell, host dependent"),
        _ => None,
    }
}

#[test]
fn every_catalog_default_matches_a_fresh_appstate() {
    let app = fresh_app();
    let mut mismatches: Vec<String> = Vec::new();
    let mut compared = 0usize;

    for def in OPTION_CATALOG.iter() {
        if exempt(def.name).is_some() {
            continue;
        }
        let actual = get_option_value(&app, def.name);
        compared += 1;
        if actual != def.default {
            mismatches.push(format!(
                "\n  {}\n      catalog default : {:?}\n      fresh AppState  : {:?}",
                def.name, def.default, actual
            ));
        }
    }

    assert!(
        mismatches.is_empty(),
        "{} of {} catalog defaults disagree with a fresh AppState. \
         customize-mode reset would change these values for a user who never touched them:{}",
        mismatches.len(),
        compared,
        mismatches.join("")
    );
}

/// Focused regression guard for the specific option this was found on.
/// Kept separate so a future regression names the option directly.
#[test]
fn status_right_catalog_default_matches_runtime_default() {
    let app = fresh_app();
    let catalog = default_for("status-right").expect("status-right must be in OPTION_CATALOG");
    let runtime = get_option_value(&app, "status-right");

    assert_eq!(
        runtime, catalog,
        "status-right advertises one default and initializes another. \
         Resetting it in customize-mode replaces the real default \
         ({runtime:?}) with {catalog:?}."
    );
}

/// The catalog is what customize-mode renders. An option missing a default there
/// cannot be reset at all, so a blank default on a non-string option is a defect.
#[test]
fn catalog_defaults_are_present_for_scalar_options() {
    let mut missing: Vec<&str> = Vec::new();
    for def in OPTION_CATALOG.iter() {
        let scalar = matches!(def.option_type, "number" | "boolean" | "choice");
        if scalar && def.default.trim().is_empty() {
            missing.push(def.name);
        }
    }
    assert!(
        missing.is_empty(),
        "these non-string options have an empty catalog default, so customize-mode \
         cannot reset them: {missing:?}"
    );
}
