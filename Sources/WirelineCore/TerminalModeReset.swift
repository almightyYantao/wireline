/// Terminal modes a child can leave behind when it dies mid-program (ssh drops
/// inside vim / htop / tmux): fed to the emulator before a new child starts in
/// the same view, so it doesn't inherit a hidden cursor, mouse tracking, the
/// alternate screen, a scroll region…
///
/// A soft reset — screen contents and scrollback stay. `ESC 7` first: leaving
/// the alternate screen with 1049 restores the *primary* screen's saved
/// cursor, and when we're already on the primary that's the save just made,
/// so the cursor stays put (with nothing saved, some emulators would home it).
/// Each saved cursor is per screen in xterm, SwiftTerm and Ghostty. DECSTBM
/// homes the cursor, hence the second save/restore around it.
public enum TerminalModeReset {
    public static let afterChildExit: String = [
        "\u{1b}7", "\u{1b}[?1049l",                 // leave the alternate screen, cursor in place
        "\u{1b}7", "\u{1b}[r", "\u{1b}8",           // full-screen scroll region
        "\u{1b}[?1000l", "\u{1b}[?1002l", "\u{1b}[?1003l",   // mouse tracking off
        "\u{1b}[?1006l", "\u{1b}[?1015l",           // mouse encodings back to default
        "\u{1b}[?1004l",                            // focus reports off
        "\u{1b}[?2004l",                            // bracketed paste off
        "\u{1b}[?1l", "\u{1b}>",                    // normal cursor keys, numeric keypad
        "\u{1b}[?25h",                              // show the cursor
        "\u{1b}[0m"                                 // default colours and attributes
    ].joined()
}
