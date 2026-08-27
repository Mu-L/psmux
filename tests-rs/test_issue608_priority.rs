// Issue #608: psmux's own processes ran at Normal with no foreground boost.
//
// The measurement that motivated this lives in the E2E suite
// (tests/test_issue608_priority.ps1). What is pinned HERE is the parsing and
// precedence around it, because every one of those rules is a place where a
// typo could silently leave the class where it was and look like it worked:
//
//   * only three values are accepted, and the aliases for the middle one
//   * everything else is rejected rather than coerced
//   * PSMUX_PRIORITY outranks the `priority` option
//   * an unusable PSMUX_PRIORITY falls back to the option, then to the default
//   * the option round trips through apply_set_option and show-options
//
// Env-mutating tests serialise through crate::util::lock_test_env(), the single
// process-wide lock, because std::env::set_var is process global and a reader
// in another module can otherwise observe a half-swapped environment.

use crate::platform::{
    current_process_priority, normalize_priority, resolve_priority, set_process_priority,
    DEFAULT_PRIORITY, PRIORITY_VALUES,
};

fn fresh_app() -> crate::types::AppState {
    crate::types::AppState::new("i608_probe".to_string())
}

/// Set or clear PSMUX_PRIORITY for the duration of a closure and always put the
/// previous value back, so one failing case cannot leak into the next.
fn with_env<T>(value: Option<&str>, f: impl FnOnce() -> T) -> T {
    let _lock = crate::util::lock_test_env();
    let saved = std::env::var("PSMUX_PRIORITY").ok();
    match value {
        Some(v) => std::env::set_var("PSMUX_PRIORITY", v),
        None => std::env::remove_var("PSMUX_PRIORITY"),
    }
    let out = f();
    match saved {
        Some(v) => std::env::set_var("PSMUX_PRIORITY", v),
        None => std::env::remove_var("PSMUX_PRIORITY"),
    }
    out
}

// ── value parsing ───────────────────────────────────────────────────────────

#[test]
fn the_three_documented_values_are_accepted() {
    assert_eq!(normalize_priority("normal"), Some("normal"));
    assert_eq!(normalize_priority("above-normal"), Some("above-normal"));
    assert_eq!(normalize_priority("high"), Some("high"));
}

#[test]
fn spelling_of_above_normal_is_forgiving_but_canonicalised() {
    // A user who writes it the Win32 way, or with no separator, gets the
    // option they meant. show-options must still report one spelling.
    for spelling in ["above-normal", "above_normal", "abovenormal", "ABOVE-NORMAL"] {
        assert_eq!(
            normalize_priority(spelling),
            Some("above-normal"),
            "{spelling:?} should canonicalise to above-normal"
        );
    }
}

#[test]
fn surrounding_whitespace_and_case_do_not_matter() {
    assert_eq!(normalize_priority("  HIGH  "), Some("high"));
    assert_eq!(normalize_priority("\tNormal\n"), Some("normal"));
}

#[test]
fn everything_else_is_rejected() {
    // realtime is the important one: it outranks kernel threads and a wedged
    // psmux at that class can make a machine unusable, so it is not offered at
    // any spelling. idle and below-normal would make #608 worse, not better.
    for bad in [
        "realtime", "real-time", "idle", "below-normal", "belownormal", "above", "highest", "1",
        "on", "", "   ", "abovenormalx", "nice",
    ] {
        assert_eq!(normalize_priority(bad), None, "{bad:?} must be rejected");
    }
}

#[test]
fn rejected_values_never_reach_set_process_priority() {
    // Fail closed on the parse, fail open on the syscall: a value we do not
    // understand must not turn into a call with a guessed class.
    assert!(!set_process_priority("realtime"));
    assert!(!set_process_priority("bogus"));
    assert!(!set_process_priority(""));
}

#[test]
fn the_advertised_value_list_matches_what_is_accepted() {
    // PRIORITY_VALUES is what the CLI prints when it rejects something. If it
    // drifts from the parser, the error message tells users to type a value
    // that does not work.
    for v in PRIORITY_VALUES {
        assert_eq!(normalize_priority(v), Some(*v), "{v:?} is advertised but not accepted");
    }
    assert_eq!(PRIORITY_VALUES.len(), 3);
    assert!(PRIORITY_VALUES.contains(&DEFAULT_PRIORITY));
}

// ── precedence ──────────────────────────────────────────────────────────────

#[test]
fn with_no_env_and_no_option_the_default_applies() {
    with_env(None, || {
        assert_eq!(resolve_priority(None, false), DEFAULT_PRIORITY);
    });
}

#[test]
fn the_option_is_used_when_the_env_is_unset() {
    with_env(None, || {
        assert_eq!(resolve_priority(Some("high"), false), "high");
        assert_eq!(resolve_priority(Some("normal"), false), "normal");
    });
}

#[test]
fn the_env_outranks_the_option() {
    // The escape hatch: a user who configured something unusable must be able
    // to climb out of it from the shell they start psmux in.
    with_env(Some("normal"), || {
        assert_eq!(resolve_priority(Some("high"), false), "normal");
    });
    with_env(Some("high"), || {
        assert_eq!(resolve_priority(Some("normal"), false), "high");
    });
}

#[test]
fn an_unusable_env_falls_back_to_the_option_then_the_default() {
    with_env(Some("realtime"), || {
        assert_eq!(resolve_priority(Some("high"), false), "high");
        assert_eq!(resolve_priority(None, false), DEFAULT_PRIORITY);
    });
}

#[test]
fn an_empty_env_is_treated_as_unset_not_as_an_error() {
    // `set PSMUX_PRIORITY=` in cmd leaves an empty string behind. That is a
    // user clearing the variable, not asking for a nameless class.
    with_env(Some(""), || {
        assert_eq!(resolve_priority(Some("high"), false), "high");
        assert_eq!(resolve_priority(None, false), DEFAULT_PRIORITY);
    });
    with_env(Some("   "), || {
        assert_eq!(resolve_priority(None, false), DEFAULT_PRIORITY);
    });
}

#[test]
fn an_unusable_option_falls_back_to_the_default() {
    with_env(None, || {
        assert_eq!(resolve_priority(Some("realtime"), false), DEFAULT_PRIORITY);
        assert_eq!(resolve_priority(Some(""), false), DEFAULT_PRIORITY);
    });
}

// ── option round trip ───────────────────────────────────────────────────────

#[test]
fn a_fresh_appstate_reports_the_documented_default() {
    // Deliberately NOT environment sensitive: the catalog parity test compares
    // this against OPTION_CATALOG without holding the env lock.
    assert_eq!(
        crate::server::options::get_option_value(&fresh_app(), "priority"),
        DEFAULT_PRIORITY
    );
}

#[test]
fn set_option_round_trips_through_show_options() {
    with_env(None, || {
        let mut app = fresh_app();
        for want in ["normal", "high", "above-normal"] {
            crate::server::options::apply_set_option(&mut app, "priority", want, false);
            assert_eq!(
                crate::server::options::get_option_value(&app, "priority"),
                want,
                "set-option priority {want} did not read back"
            );
        }
    });
}

#[test]
fn set_option_canonicalises_an_alias_before_storing_it() {
    with_env(None, || {
        let mut app = fresh_app();
        crate::server::options::apply_set_option(&mut app, "priority", "ABOVE_NORMAL", false);
        assert_eq!(
            crate::server::options::get_option_value(&app, "priority"),
            "above-normal"
        );
    });
}

#[test]
fn set_option_refuses_a_bad_value_and_leaves_the_previous_one() {
    with_env(None, || {
        let mut app = fresh_app();
        crate::server::options::apply_set_option(&mut app, "priority", "high", false);
        for bad in ["realtime", "idle", "bogus", "42"] {
            crate::server::options::apply_set_option(&mut app, "priority", bad, false);
            assert_eq!(
                crate::server::options::get_option_value(&app, "priority"),
                "high",
                "set-option priority {bad} should have been refused"
            );
        }
    });
}

#[test]
fn set_option_reports_the_env_override_not_the_requested_value() {
    // show-options must describe what the process is ACTUALLY running at.
    // Reporting the configured value while the env forced another one would
    // make a support conversation about #608 impossible.
    with_env(Some("normal"), || {
        let mut app = fresh_app();
        crate::server::options::apply_set_option(&mut app, "priority", "high", false);
        assert_eq!(
            crate::server::options::get_option_value(&app, "priority"),
            "normal"
        );
    });
}

#[test]
fn the_config_file_path_warns_on_a_bad_value_and_keeps_the_default() {
    // The config path is a separate match from apply_set_option, and the
    // generic catalog check only validates numbers and booleans, so a choice
    // option with no hand written arm would fall through silently.
    with_env(None, || {
        let mut app = fresh_app();
        crate::config::parse_option_value(&mut app, "priority", "realtime", true);
        assert_eq!(
            crate::server::options::get_option_value(&app, "priority"),
            DEFAULT_PRIORITY,
            "a bad config value must not change the option"
        );
        assert!(
            app.config_warnings.iter().any(|w| w.contains("priority")),
            "a bad config value must warn, got {:?}",
            app.config_warnings
        );
    });
}

#[test]
fn the_config_file_path_accepts_a_good_value() {
    with_env(None, || {
        let mut app = fresh_app();
        crate::config::parse_option_value(&mut app, "priority", "high", true);
        assert_eq!(
            crate::server::options::get_option_value(&app, "priority"),
            "high"
        );
        assert!(
            !app.config_warnings.iter().any(|w| w.contains("priority")),
            "a good config value must not warn, got {:?}",
            app.config_warnings
        );
    });
}

// ── the syscall itself ──────────────────────────────────────────────────────

#[test]
#[cfg(windows)]
fn setting_the_class_takes_effect_and_can_be_put_back() {
    // Runs in the test process, so it must restore what it found or every
    // later test in this binary runs at whatever class it happened to leave.
    let _lock = crate::util::lock_test_env();
    let before = current_process_priority();
    for want in ["normal", "above-normal"] {
        assert!(set_process_priority(want), "SetPriorityClass({want}) refused");
        assert_eq!(current_process_priority(), Some(want));
    }
    if let Some(b) = before {
        set_process_priority(b);
    } else {
        set_process_priority("normal");
    }
}
