// Issue #265: argv parser drops -e args after a value ending in backslash + spaces
//
// Root cause: spawn_server_hidden in src/platform.rs serialised argv to a
// command line by naively wrapping each value in `"..."` and replacing only
// embedded `"`. For a value with spaces ending in `\`, that produced
// `"VAL\"` which the receiver's CommandLineToArgvW reads as an escaped quote
// (NOT a closing quote), so the next arg gets swallowed.
//
// These tests verify the fix: escape_arg_msvcrt follows Microsoft's
// CommandLineToArgvW rules — backslash runs that immediately precede a
// `"` (including the closing quote) are doubled.

use super::escape_arg_msvcrt;

#[test]
fn no_special_chars_no_quoting() {
    assert_eq!(escape_arg_msvcrt("plain"), "plain");
    assert_eq!(escape_arg_msvcrt("KEY=VAL"), "KEY=VAL");
    // Backslashes alone (no quote nearby) do not require doubling.
    assert_eq!(escape_arg_msvcrt("C:\\Users\\x"), "C:\\Users\\x");
}

#[test]
fn empty_arg_is_quoted() {
    assert_eq!(escape_arg_msvcrt(""), "\"\"");
}

#[test]
fn space_in_value_is_quoted() {
    assert_eq!(
        escape_arg_msvcrt("hello world"),
        "\"hello world\""
    );
}

#[test]
fn embedded_quote_is_escaped() {
    assert_eq!(
        escape_arg_msvcrt(r#"say "hi""#),
        r#""say \"hi\"""#
    );
}

#[test]
fn issue265_value_with_spaces_and_trailing_backslash() {
    // The value that breaks the naive serialiser:
    //   `C:\Program Files\Foo Bar\plugins\` (spaces + trailing `\`)
    // Naive output (BUG): "C:\Program Files\Foo Bar\plugins\"
    //   -> receiver sees `\"` as escaped quote, swallows next arg.
    // Correct output: "C:\Program Files\Foo Bar\plugins\\"
    //   -> receiver sees `\\` as one literal `\` and `"` as close quote.
    let arg = r"C:\Program Files\Foo Bar\plugins\";
    let escaped = escape_arg_msvcrt(arg);
    assert_eq!(
        escaped,
        r#""C:\Program Files\Foo Bar\plugins\\""#,
        "trailing backslash run before closing quote must be doubled"
    );
}

#[test]
fn backslashes_not_before_quote_pass_through() {
    // Even when the arg requires quoting (because of a space), interior
    // backslashes that don't precede a quote stay single.
    let arg = r"C:\Program Files\X";
    assert_eq!(
        escape_arg_msvcrt(arg),
        r#""C:\Program Files\X""#
    );
}

#[test]
fn backslashes_before_embedded_quote_doubled() {
    // For input `\"` inside an arg, MSVCRT rules: 1 backslash before a
    // literal `"` becomes `\\\"` (2 escape backslashes + escaped quote).
    let arg = r#"a\"b"#;
    assert_eq!(
        escape_arg_msvcrt(arg),
        r#""a\\\"b""#
    );
}

#[test]
fn multiple_trailing_backslashes_doubled() {
    let arg = r"foo bar\\\";
    // 3 trailing backslashes -> 6 in the quoted form
    assert_eq!(
        escape_arg_msvcrt(arg),
        r#""foo bar\\\\\\""#
    );
}

#[test]
fn tab_triggers_quoting() {
    // tmux often passes args with tabs; ensure they trigger quoting.
    let arg = "a\tb";
    assert_eq!(escape_arg_msvcrt(arg), "\"a\tb\"");
}

#[test]
fn roundtrip_via_commandlinetoargvw() {
    // The ultimate proof: round-trip our escaper through the same parser
    // CreateProcessW children use. Whatever we put in must come back out
    // verbatim.
    use std::os::windows::ffi::OsStrExt;
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;

    #[link(name = "shell32")]
    extern "system" {
        fn CommandLineToArgvW(
            lpCmdLine: *const u16,
            pNumArgs: *mut i32,
        ) -> *mut *mut u16;
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn LocalFree(h: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    }

    let cases: &[&str] = &[
        r#"C:\Program Files\Foo Bar\plugins\"#,
        r#"C:\Program Files\Foo Bar\plugins"#,
        r#"plain"#,
        r#"value with spaces"#,
        r#"value with "quote""#,
        r#"trailing\\\\"#,
        r#"a\"b"#,
        "",
    ];

    for &original in cases {
        // Build a synthetic command line: dummy.exe arg1 arg2
        let cmdline = format!(
            "dummy.exe {} marker",
            escape_arg_msvcrt(original)
        );
        let wide: Vec<u16> = std::ffi::OsStr::new(&cmdline)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut argc: i32 = 0;
        let argv = unsafe { CommandLineToArgvW(wide.as_ptr(), &mut argc) };
        assert!(!argv.is_null(), "CommandLineToArgvW returned null");
        // Expect exactly 3 args: exe, the arg under test, and "marker"
        assert_eq!(argc, 3, "wrong argc for input {:?} -> cmdline {:?}", original, cmdline);

        let parsed: Vec<String> = (0..argc as isize)
            .map(|i| unsafe {
                let p = *argv.offset(i);
                let mut len = 0;
                while *p.offset(len) != 0 { len += 1; }
                let slice = std::slice::from_raw_parts(p, len as usize);
                OsString::from_wide(slice).to_string_lossy().into_owned()
            })
            .collect();
        unsafe { LocalFree(argv as *mut _); }

        assert_eq!(
            parsed[1], original,
            "round-trip mismatch: input {:?} -> cmdline {:?} -> parsed[1] {:?}",
            original, cmdline, parsed[1]
        );
        assert_eq!(parsed[2], "marker", "marker arg must survive: input {:?}", original);
    }
}
