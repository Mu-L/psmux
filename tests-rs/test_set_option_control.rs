use super::*;

fn rejected_control_command(command: &str, args: &[&str]) -> String {
    let (request_tx, request_rx) = mpsc::channel();
    let (response_tx, response_rx) = mpsc::channel();
    assert!(dispatch_control_command(
        command,
        args,
        &request_tx,
        response_tx,
        None,
        false,
        None,
        0,
    ));
    let response = response_rx.recv().unwrap();
    assert!(response.starts_with("\u{0001}ERR\u{0001}"));
    assert!(matches!(
        request_rx.try_recv(),
        Err(mpsc::TryRecvError::Empty),
    ));
    response
}

#[test]
fn combined_target_flags_consume_the_target_before_the_option_name() {
    let parsed = parse_set_option_args(&[
        "-gat",
        "target",
        "history-limit",
        "42",
    ]);
    assert_eq!(parsed.flag_chars, "gat");
    assert_eq!(parsed.target, Some("target"));
    assert_eq!(parsed.positionals, ["history-limit", "42"]);
}

#[test]
fn target_last_is_supported_and_dash_dash_preserves_literal_target_tokens() {
    let target_last = parse_set_option_args(&[
        "mouse",
        "on",
        "-t",
        "target",
    ]);
    assert_eq!(target_last.target, Some("target"));
    assert_eq!(target_last.positionals, ["mouse", "on"]);

    let literal = parse_set_option_args(&[
        "@value",
        "--",
        "-t",
        "target",
    ]);
    assert_eq!(literal.target, None);
    assert_eq!(literal.positionals, ["@value", "-t", "target"]);
}

#[test]
fn dangling_target_is_rejected_without_dispatch() {
    let parsed = parse_set_option_args(&["mouse", "off", "-t"]);
    assert!(parsed.missing_target);
    assert!(parsed.validate(false).is_err());

    let response = rejected_control_command(
        "set-option",
        &["-g", "mouse", "off", "-t"],
    );
    assert!(response.contains("target required"));
}

#[test]
fn malformed_flag_tokens_remain_flags_for_cli_rejection() {
    let parsed = parse_set_option_args(&[
        "-g1",
        "history-limit",
        "42",
    ]);
    assert_eq!(parsed.flag_chars, "g1");
    assert_eq!(parsed.target, None);
    assert_eq!(parsed.positionals, ["history-limit", "42"]);
}

#[test]
fn control_mode_rejects_malformed_flag_tokens() {
    let response = rejected_control_command(
        "set-option",
        &["-g1t", ":1", "history-limit", "42"],
    );
    assert!(response.contains("unknown flag -1"));
}

#[test]
fn missing_option_name_is_rejected_without_dispatch() {
    let response = rejected_control_command("set-option", &["-g"]);
    assert!(response.contains("too few arguments"));
}

#[test]
fn targeted_invalid_assignment_is_rejected_without_dispatch() {
    let response = rejected_control_command(
        "set-option",
        &["-gt", ":1", "history-limit"],
    );
    assert!(response.contains("empty value"));
}

#[test]
fn multi_token_integer_is_rejected_without_dispatch() {
    let response = rejected_control_command(
        "set-option",
        &["-g", "history-limit", "42", "junk"],
    );
    assert!(response.contains("42 junk"));
}

#[test]
fn negative_integer_is_rejected_without_dispatch() {
    let response = rejected_control_command(
        "set-option",
        &["-g", "history-limit", "-1"],
    );
    assert!(response.contains("-1"));
}

#[test]
fn numeric_options_use_catalog_destination_ranges() {
    use crate::server::option_catalog::{NumberKind, OptionType, OPTION_CATALOG};

    let cases = [
        ("main-pane-width", NumberKind::U16, u16::MAX as u128),
        ("escape-time", NumberKind::U64, u64::MAX as u128),
        ("history-limit", NumberKind::Usize, usize::MAX as u128),
        ("base-index", NumberKind::Index, isize::MAX as u128),
        ("pane-base-index", NumberKind::Index, isize::MAX as u128),
    ];

    for (name, expected_kind, maximum) in cases {
        let definition = OPTION_CATALOG
            .iter()
            .find(|definition| definition.name == name)
            .unwrap();
        assert_eq!(definition.option_type, OptionType::Number(expected_kind));
        let maximum = maximum.to_string();
        assert!(
            parse_set_option_args(&["-g", name, &maximum])
                .validate(false)
                .is_ok(),
            "{name} should accept {maximum}",
        );

        let too_large = (maximum.parse::<u128>().unwrap() + 1).to_string();
        assert!(
            parse_set_option_args(&["-g", name, &too_large])
                .validate(false)
                .is_err(),
            "{name} should reject {too_large}",
        );
    }
}

#[test]
fn index_options_reject_negative_and_malformed_values() {
    for name in ["base-index", "pane-base-index"] {
        for value in ["-1", "1x"] {
            assert!(
                parse_set_option_args(&["-g", name, value])
                    .validate(false)
                    .is_err(),
                "{name} should reject {value}",
            );
        }
    }
}

#[test]
fn validation_only_numeric_options_preserve_cli_compatibility() {
    use crate::server::option_catalog::{OPTION_CATALOG, VALIDATION_ONLY_OPTIONS};

    for name in ["message-limit", "history-file-limit"] {
        assert!(
            OPTION_CATALOG
                .iter()
                .all(|definition| definition.name != name),
            "{name} is validation-only and must not appear in option listings",
        );
        assert!(
            VALIDATION_ONLY_OPTIONS
                .iter()
                .any(|definition| definition.name == name),
            "{name} must have explicit validation metadata",
        );
        assert!(
            parse_set_option_args(&["-g", name, "-1"])
                .validate(false)
                .is_ok(),
            "{name} historically accepts signed integers",
        );
        assert!(
            parse_set_option_args(&["-g", name, "invalid"])
                .validate(false)
                .is_err(),
            "{name} should reject malformed integers",
        );
    }
}
