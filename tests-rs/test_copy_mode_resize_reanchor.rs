// Issue: a pane resize while in copy mode stranded the view at the top.
//
// Live reproduction (phone client, on-screen keyboard toggling the pane
// height): mode=1, scroll=3771 of hist=4359 -> the resize dropped retained
// history to 508 while the offset went to 4390, and the view settled at
// scroll == history_size, i.e. line 1, until the user pressed Esc.
//
// `copy_scroll_offset` counts lines above the live bottom, so a trim of N
// retained lines must shift it down by N to keep showing the same content.


#[test]
fn no_trim_keeps_the_offset() {
    assert_eq!(crate::copy_mode::offset_after_trim(10, 100, 100), Some(10));
    assert_eq!(crate::copy_mode::offset_after_trim(10, 100, 200), Some(10));
}

#[test]
fn a_trim_shifts_the_offset_by_the_dropped_lines() {
    // 100 -> 90 retained lines: 10 lines dropped off the old end, so an offset
    // of 30 now sits 20 lines above the bottom and shows the same content.
    assert_eq!(crate::copy_mode::offset_after_trim(30, 100, 90), Some(20));
}

#[test]
fn a_trim_below_the_offset_clamps_to_the_live_bottom() {
    assert_eq!(crate::copy_mode::offset_after_trim(5, 100, 2), Some(0));
}

#[test]
fn an_offset_beyond_the_old_history_can_no_longer_be_anchored() {
    // The resize happened while the offset already pointed past the retained
    // history (the live case): there is nothing to re-anchor to, so the caller
    // must drop back to the live view instead of pinning the pane at line 1.
    assert_eq!(crate::copy_mode::offset_after_trim(4390, 4366, 508), None);
    assert_eq!(crate::copy_mode::offset_after_trim(150, 100, 10), None);
}

#[test]
fn landing_exactly_on_the_top_of_the_new_history_is_still_valid() {
    assert_eq!(crate::copy_mode::offset_after_trim(100, 100, 40), Some(40));
}
