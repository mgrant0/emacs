#!/bin/bash
# test-tty-scrollbar.sh - Automated TTY vertical scroll bar mouse tests
#
# Usage:
#   ./test-tty-scrollbar.sh          - Run all automated tests
#   ./test-tty-scrollbar.sh attach   - Attach to running session (interactive)
#   ./test-tty-scrollbar.sh cap      - Capture current screen
#   ./test-tty-scrollbar.sh kill     - Kill session
#
# Tests:
#   0. GUI default — verify scroll bar appears on the side that matches
#      default-frame-scroll-bars (right for GTK+toolkit, left otherwise)
#
# Tests (left scroll bar, xterm col 1):
#   1. Click above thumb  → page up
#   2. Click below thumb  → page down
#   3. Drag thumb upward (scroll bar only) → live scroll, no escape codes
#   4. Drag thumb right into text area → live scroll (y only), no escape codes
#
# Tests (right scroll bar, xterm col 80):
#   5. Layout check: text area shrunk to cols 0–78, SB at col 79
#   6. Click above thumb  → page up
#   7. Click below thumb  → page down
#   8. Drag thumb upward (scroll bar only) → live scroll, no escape codes
#   9. Drag thumb left into text area → live scroll (y only), no escape codes
#
# Thumb geometry tests (left scroll bar):
#  10. ws=line  1 → thumb at top    (start=0,  end=5)
#  11. ws=line 89 → thumb at bottom (start=17, end=22)
#  12. 10-line buffer → full-height thumb (start=0, end=22)
#  13. ws=line 44 → thumb height=5 rows
#  14. ws=line 23 → thumb_start=4 (midpoint)
#  15. Grab-point: click at thumb row 11, drag to row 6 → window at line ~16, not ~26
#  16. Vertical split (split-window-right): border '|' between windows (left SB)
#  17. Vertical split with right scroll bar: '|' visible in SB track column
#  18. window-divider-mode: both scroll bar and '|' border present after split
#  19. Scrolling left window does not alter right window's scroll bar geometry
#  20. Adding lines to left window does not alter right window's scroll bar
#  21. Drag '|' border left/right — window sizes change (vertical resize)
#  22. window-divider-mode: scroll bar click scrolls (not resizes window)

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SOCKET="/tmp/emacs-sb-test-tmux"
SESSION="emacs-sb"
# Resolve to absolute path so it stays valid when tmux cd's elsewhere.
EMACS="$(cd "$(dirname "${EMACS:-./src/emacs}")" 2>/dev/null && pwd)/$(basename "${EMACS:-./src/emacs}")"
LOGDIR="/tmp/emacs-sb-logs"
PANE_LOG="$LOGDIR/pane.log"
RESULT_FILE="/tmp/emacs-sb-result.txt"
# Frame geometry (no menu bar — we disable it in setup)
WIDTH=80
HEIGHT=24
WIN_HT=22   # HEIGHT - 1 modeline - 1 minibuffer

PASS=0
FAIL=0

# ── Color output ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

die()    { echo "FATAL: $*" >&2; exit 1; }
info()   { echo "INFO: $*"; }
pass()   { PASS=$((PASS + 1)); echo -e "${GREEN}PASS${NC}: $*"; }
fail()   { FAIL=$((FAIL + 1)); echo -e "${RED}FAIL${NC}: $*"; }
header() { echo -e "\n${BOLD}══════ $* ══════${NC}"; }

# ── tmux helpers ──────────────────────────────────────────────────────────────

# Send raw bytes (including ESC) to the pane via load-buffer + paste-buffer.
send_raw() {
    printf '%s' "$1" | tmux -S "$SOCKET" load-buffer -
    tmux -S "$SOCKET" paste-buffer -t "$SESSION" -d
}

# Send tmux-named keys (Enter, Escape, C-v, M-:, …)
send_key() {
    tmux -S "$SOCKET" send-keys -t "$SESSION" "$@"
}

# Capture current pane content.
capture() {
    tmux -S "$SOCKET" capture-pane -t "$SESSION" -p
}

# Capture screen and append to pane log.
snap() {
    local label="${1:-}"
    printf '\n=== %s ===\n' "$label" >> "$PANE_LOG"
    capture | tee -a "$PANE_LOG"
}

# ── SGR 1006 mouse helpers (1-indexed coordinates) ────────────────────────────
#
# Emacs subtracts 1 inside xterm-mouse--read-event-sequence, so:
#   xterm col 1 → frame col 0   (left scroll bar column)
#   xterm row 1 → frame row 0   (top of frame / top of window when no menu bar)
#
# With menu bar disabled and no tool bar (-Q):
#   Window body: xterm y=1..WIN_HT=22
#   Modeline:    xterm y=23
#   Minibuffer:  xterm y=24
#
# SGR format:  ESC [ < BTN ; COL ; ROW FINAL
#   BTN 0  = left button press/release
#   BTN 32 = motion with left button held (0 + motion-flag 32)
#   FINAL M = press or motion,  m = release

sgr_mouse() {
    local btn=$1 col=$2 row=$3 final=$4
    send_raw "$(printf '\033[<%d;%d;%d%s' "$btn" "$col" "$row" "$final")"
}

mouse_down() { sgr_mouse 0  "$1" "$2" M; }
mouse_up()   { sgr_mouse 0  "$1" "$2" m; }
mouse_move() { sgr_mouse 32 "$1" "$2" M; }

mouse_click() {
    mouse_down "$1" "$2"
    sleep 0.15
    mouse_up   "$1" "$2"
}

# ── Lisp helpers ──────────────────────────────────────────────────────────────

# Evaluate LISP_EXPR via M-: and write result to RESULT_FILE.
# With debug-on-error nil and condition-case wrapping in each expression,
# the minibuffer closes cleanly after Enter and there is nothing to dismiss.
_eval_via_mx() {
    local expr="$1"
    rm -f "$RESULT_FILE"
    sleep 0.1          # let any previous redisplay settle
    send_key "M-:" ""
    sleep 0.15
    send_raw "$expr"
    sleep 0.05
    send_key "" Enter
    sleep 0.6
}

# Return the line number at window-start of *scrolltest* as a plain integer.
get_top_line() {
    local expr
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (insert (number-to-string
              (with-current-buffer "*scrolltest*"
                (line-number-at-pos
                 (window-start (get-buffer-window "*scrolltest*")))))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    cat "$RESULT_FILE" 2>/dev/null | grep -oP '^\d+' || echo ""
}

# Return "CLEAN" if *scrolltest* contains no "[<" escape fragments, else "DIRTY".
check_buffer_clean() {
    local expr
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (insert (if (with-current-buffer "*scrolltest*"
                   (save-excursion
                     (goto-char (point-min))
                     (search-forward "[<" nil t)))
                 "DIRTY" "CLEAN")))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    cat "$RESULT_FILE" 2>/dev/null | tr -d ' \n' || echo ""
}

# ── Session management ────────────────────────────────────────────────────────

start_session() {
    [ -x "$EMACS" ] || die "Emacs binary not found: $EMACS"
    command -v tmux >/dev/null || die "tmux not found"

    mkdir -p "$LOGDIR"
    rm -f "$PANE_LOG"

    tmux -S "$SOCKET" kill-server 2>/dev/null || true
    sleep 0.3

    info "Starting tmux -vv (logs → $LOGDIR/tmux-server-*.log)"
    # -vv: verbose; cd to LOGDIR so log files land there.
    (cd "$LOGDIR" && tmux -vv -S "$SOCKET" new-session -d -s "$SESSION" \
         -x "$WIDTH" -y "$HEIGHT" \
         "$EMACS" -Q -nw) 2>/dev/null

    sleep 2.5   # wait for Emacs startup

    # Pipe all pane output to PANE_LOG for inspection.
    tmux -S "$SOCKET" pipe-pane -t "$SESSION" "cat >> '$PANE_LOG'"

    info "Configuring Emacs (scroll bar, mouse, no debugger) …"
    # Use M-: to set up:
    #   - no menu bar (saves one frame row → WIN_HT=22)
    #   - left scroll bar
    #   - xterm-mouse-mode with SGR 1006
    #   - debug-on-error off (prevents debugger hijacking the frame)
    local setup
    setup='(progn
  (menu-bar-mode -1)
  (set-scroll-bar-mode (quote left))
  (xterm-mouse-mode 1)
  (setq xterm-mouse-utf-8 nil)
  (setq debug-on-error nil)
  (message "Setup: sb=%s mouse=%s dbg=%s"
           (frame-parameter nil (quote vertical-scroll-bars))
           xterm-mouse-mode
           debug-on-error))'
    send_key "M-:" ""
    sleep 0.15
    send_raw "$setup"
    sleep 0.05
    send_key "" Enter
    sleep 1.2
    snap "after-setup"
}

# Fill *scrolltest* with LINES numbered lines, window-start at WIN_START_LINE,
# cursor at CURSOR_LINE.  Window-start and cursor line are both 1-indexed.
setup_buffer() {
    local lines="$1" win_start_line="$2" cursor_line="$3"
    info "Filling *scrolltest*: $lines lines, window-start=L$win_start_line, cursor=L$cursor_line"

    # Build a single-line Lisp expression.
    # printf %%03d → %03d  (literal percent for Lisp's format)
    # printf \\n   → \n    (two-char Lisp newline escape)
    local expr
    expr=$(printf \
'(progn
  (switch-to-buffer "*scrolltest*")
  (erase-buffer)
  (dotimes (i %d) (insert (format "Line %%03d\\n" (1+ i))))
  (let ((ws-pos (progn (goto-char (point-min)) (forward-line %d) (point)))
        (cur-pos (progn (goto-char (point-min)) (forward-line %d) (point))))
    (set-window-start (selected-window) ws-pos)
    (goto-char cur-pos))
  (message "Buffer: %d lines, ws=L%d cur=L%d"))' \
        "$lines" \
        "$((win_start_line - 1))" \
        "$((cursor_line - 1))" \
        "$lines" "$win_start_line" "$cursor_line")

    send_key "M-:" ""
    sleep 0.15
    send_raw "$expr"
    sleep 0.05
    send_key "" Enter
    sleep 1.0
    snap "after-setup-buffer"
}

# ── Test cases ────────────────────────────────────────────────────────────────
#
# Buffer layout:  110 lines, "Line NNN\n" = 9 chars each → buf_size=990
# Window:         height=22 (no menu bar)
# Scroll bar:     left, xterm col=1 → frame col=0
# Position:       window-start=L44 (char 387), cursor=L55, window shows L44-L65
#
# Thumb calculation (from tty_apply_scroll_bar_glyphs_for_window):
#   win_start = 387,  portion = 22×9 = 198,  buf_size = 990
#   track_above = floor(387 × 22 / 990) = 8
#   below_chars = 990 − 387 − 198 = 405
#   track_below = floor(405 × 22 / 990) = 9
#   thumb rows (0-indexed): 8 … 12        xterm y: 9 … 13
#
# Test click coordinates (xterm, 1-indexed):
#   SB_COL=1  Y_ABOVE=5  (sb_row=4  <  8  → above-handle)
#   SB_COL=1  Y_BELOW=18 (sb_row=17 ≥  13 → below-handle)
#   SB_COL=1  Y_THUMB=11 (sb_row=10 ∈ [8,12] → handle)

SB_COL=1       # xterm x=1  → frame col=0  (left scroll bar)
SB_COL_RIGHT=80 # xterm x=80 → frame col=79 (right scroll bar on 80-col frame)
Y_ABOVE=5   # clearly above the thumb
Y_BELOW=18  # clearly below the thumb
Y_THUMB=11  # on the thumb handle
LINES=110   # 5 × WIN_HT
WS_LINE=44  # window-start line
CUR_LINE=55 # cursor / centre line

run_test0() {
    header "Test 0: GUI default — scroll bar appears on the side matching default-frame-scroll-bars"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    # Query the compiled-in GUI default.
    # Emacs sets default-frame-scroll-bars at build time:
    #   GTK + USE_TOOLKIT_SCROLL_BARS → right
    #   other X11                     → left
    #   non-windowed build            → nil
    local expr expected_side
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (insert (if (symbolp default-frame-scroll-bars)
                 (symbol-name default-frame-scroll-bars)
               "nil")))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    expected_side=$(cat "$RESULT_FILE" 2>/dev/null | tr -d ' \n' || echo "")
    info "default-frame-scroll-bars = '${expected_side:-?}'"

    if [ -z "$expected_side" ] || [ "$expected_side" = "nil" ]; then
        pass "Test 0: default-frame-scroll-bars is nil (non-windowed build) — no default side to check"
        return
    fi
    if [ "$expected_side" != "left" ] && [ "$expected_side" != "right" ]; then
        fail "Test 0: unexpected default-frame-scroll-bars value: '${expected_side}'"
        return
    fi

    # Apply the compiled-in default (overrides the 'left forced in start_session).
    set_scroll_bar_side "$expected_side"

    # Query actual scroll bar side and text-area geometry.
    local result sb_side text_left text_right
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((ie   (window-inside-edges))
            (side (frame-parameter nil (quote vertical-scroll-bars)))
            (left (nth 0 ie))
            (right (nth 2 ie)))
       (insert (format "%%s %%d %%d" side left right))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null | tr -d '\n' || echo "")
    sb_side=$(  printf '%s' "$result" | awk '{print $1}')
    text_left=$(printf '%s' "$result" | awk '{print $2}')
    text_right=$(printf '%s' "$result" | awk '{print $3}')
    info "Geometry: sb=$sb_side text_left=$text_left text_right=$text_right"
    snap "t0-layout"

    # 0a: actual side matches compiled-in default
    if [ "$sb_side" = "$expected_side" ]; then
        pass "Test 0a: scroll bar side = '$sb_side' matches GUI default (default-frame-scroll-bars)"
    else
        fail "Test 0a: scroll bar side = '${sb_side:-?}', expected '$expected_side'"
        info "Screen:"; capture
    fi

    # 0b: text-area geometry is correct for the expected side
    # 0c: visual — first character of a "Line NNN" row
    #
    # right SB: SB at frame col WIDTH-1; text occupies cols 0 … WIDTH-2
    #   window-inside-edges LEFT=0  RIGHT=WIDTH-1
    #   screen col 0 = 'L' (text starts at left edge)
    #
    # left SB:  SB at frame col 0;       text occupies cols 1 … WIDTH-1
    #   window-inside-edges LEFT=1  RIGHT=WIDTH
    #   screen col 0 = ' ' (SB glyph displaces text one column right)
    local expected_left expected_right first_char
    if [ "$expected_side" = "right" ]; then
        expected_left=0
        expected_right=$((WIDTH - 1))
    else
        expected_left=1
        expected_right=$WIDTH
    fi

    if [ "$text_left" = "$expected_left" ] && [ "$text_right" = "$expected_right" ]; then
        pass "Test 0b: text area cols $expected_left–$((expected_right-1)) (width $((expected_right-expected_left))); SB at expected col"
    else
        fail "Test 0b: expected text cols $expected_left–$((expected_right-1)), got left=$text_left right=$text_right"
    fi

    first_char=$(capture | grep -m1 "Line 04" | cut -c1)
    if [ "$expected_side" = "right" ]; then
        if [ "$first_char" = "L" ]; then
            pass "Test 0c: screen col 0 = 'L' — text is flush-left, right SB does not displace text"
        else
            fail "Test 0c: screen col 0 = '${first_char:-?}', expected 'L' (text flush-left with right SB)"
            info "Screen:"; capture
        fi
    else
        if [ "$first_char" = " " ]; then
            pass "Test 0c: screen col 0 = ' ' — left SB glyph displaces text to col 1"
        else
            fail "Test 0c: screen col 0 = '${first_char:-?}', expected ' ' (left SB glyph at col 0)"
            info "Screen:"; capture
        fi
    fi

    # Restore left so tests 1–4 run under predictable conditions.
    set_scroll_bar_side left
}

run_test1() {
    header "Test 1: Click above thumb → page up"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after
    before=$(get_top_line)
    info "Window top before: line ${before:-?}"
    snap "t1-before"

    mouse_click $SB_COL $Y_ABOVE
    sleep 0.6
    snap "t1-after"

    after=$(get_top_line)
    info "Window top after:  line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 1: click above thumb → page UP  ($before → $after)"
    else
        fail "Test 1: expected page UP, got before='$before' after='$after'"
        info "Screen:"; capture
    fi
}

run_test2() {
    header "Test 2: Click below thumb → page down"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after
    before=$(get_top_line)
    info "Window top before: line ${before:-?}"
    snap "t2-before"

    mouse_click $SB_COL $Y_BELOW
    sleep 0.6
    snap "t2-after"

    after=$(get_top_line)
    info "Window top after:  line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        pass "Test 2: click below thumb → page DOWN ($before → $after)"
    else
        fail "Test 2: expected page DOWN, got before='$before' after='$after'"
        info "Screen:"; capture
    fi
}

run_test3() {
    header "Test 3: Drag thumb upward (within scroll bar) → live scroll, clean buffer"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after clean
    before=$(get_top_line)
    info "Window top before drag: line ${before:-?}"
    snap "t3-before"

    # Press down on the handle
    mouse_down $SB_COL $Y_THUMB
    sleep 0.35

    # Drag upward, staying in the scroll bar column
    local row
    for row in 10 9 8 7 6 5 4 3; do
        mouse_move $SB_COL $row
        sleep 0.12
    done

    # Release at xterm y=3  (sb_row=2 → ~9% into buffer ≈ line 10)
    mouse_up $SB_COL 3
    sleep 0.6
    snap "t3-after"

    after=$(get_top_line)
    info "Window top after drag: line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 3a: drag up scrolled buffer UP ($before → $after)"
    else
        fail "Test 3a: expected UP scroll from drag, got before='$before' after='$after'"
        info "Screen:"; capture
    fi

    clean=$(check_buffer_clean)
    info "Buffer check: $clean"
    case "$clean" in
        CLEAN) pass "Test 3b: no escape codes in buffer during drag (read-key path works)" ;;
        DIRTY) fail "Test 3b: escape codes found in buffer (is read-event used instead of read-key?)"; capture ;;
        *)     fail "Test 3b: buffer check returned no result (eval error?)"; capture ;;
    esac
}

run_test4() {
    header "Test 4: Drag thumb into text area (x moves right) → live scroll by y only, clean buffer"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after clean
    before=$(get_top_line)
    info "Window top before drag: line ${before:-?}"
    snap "t4-before"

    # Press down on the handle in the scroll bar
    mouse_down $SB_COL $Y_THUMB
    sleep 0.35

    # Drag upward AND rightward — x enters the text area (col > 1).
    # The drag function uses only xterm-mouse-y, so x must NOT matter.
    # Also, no escape-code fragments should appear in the buffer.
    local pair col row
    for pair in "1 10" "4 9" "8 8" "13 7" "18 6" "24 5" "30 4" "36 3"; do
        col="${pair% *}"
        row="${pair#* }"
        mouse_move "$col" "$row"
        sleep 0.12
    done

    # Release inside the text area (col 36, row 3)
    mouse_up 36 3
    sleep 0.6
    snap "t4-after"

    after=$(get_top_line)
    info "Window top after drag: line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 4a: drag into text area scrolled buffer UP ($before → $after)"
    else
        fail "Test 4a: expected UP scroll from cross-area drag, got before='$before' after='$after'"
        info "Screen:"; capture
    fi

    clean=$(check_buffer_clean)
    info "Buffer check: $clean"
    case "$clean" in
        CLEAN) pass "Test 4b: no escape codes inserted during cross-area drag" ;;
        DIRTY) fail "Test 4b: escape codes found in buffer during cross-area drag"; capture ;;
        *)     fail "Test 4b: buffer check returned no result (eval error?)"; capture ;;
    esac
}

# Switch the scroll bar to the given side ('left or 'right) via M-:.
set_scroll_bar_side() {
    local side="$1"
    info "Switching scroll bar to $side"
    _eval_via_mx "(set-scroll-bar-mode (quote $side))"
    sleep 0.5
    snap "after-sb-$side"
}

# ── Right scroll bar tests ────────────────────────────────────────────────────
#
# Right scroll bar geometry (80-col frame, no menu bar):
#   frame col = window-left-column + window-total-width - 1 = 0 + 80 - 1 = 79
#   xterm col = 79 + 1 = 80  → SB_COL_RIGHT=80
#
# Thumb position is identical to left-side tests (same buffer layout):
#   track_above=8, track_below=8 → thumb at xterm y 9–14
#   Y_ABOVE=5, Y_BELOW=18, Y_THUMB=11 unchanged

run_test5() {
    header "Test 5: Right SB layout — text area shrunk, SB on right of text"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    # ── Lisp geometry check ──────────────────────────────────────────────────
    # window-inside-edges returns (LEFT TOP RIGHT BOTTOM) of the text-only area,
    # excluding scroll bar, fringes, and margins.
    #
    # Right SB on 80-col frame:
    #   SB at frame col 79  →  text LEFT=0, text RIGHT=79 (width=79)
    # Left SB on 80-col frame:
    #   SB at frame col 0   →  text LEFT=1, text RIGHT=80 (width=79)
    local expr result sb_side text_left text_right
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((ie    (window-inside-edges))
            (side  (frame-parameter nil (quote vertical-scroll-bars)))
            (left  (nth 0 ie))
            (right (nth 2 ie)))
       (insert (format "%%s %%d %%d" side left right))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null | tr -d '\n' || echo "")
    sb_side=$(  printf '%s' "$result" | awk '{print $1}')
    text_left=$(printf '%s' "$result" | awk '{print $2}')
    text_right=$(printf '%s' "$result" | awk '{print $3}')
    info "Geometry: sb=$sb_side text_left=$text_left text_right=$text_right"

    # 5a: frame parameter says 'right
    if [ "$sb_side" = "right" ]; then
        pass "Test 5a: frame parameter vertical-scroll-bars = right"
    else
        fail "Test 5a: frame parameter vertical-scroll-bars = '${sb_side:-?}', expected right"
    fi

    # 5b: text area begins at col 0 (not displaced right by a left SB)
    #     and ends at col WIDTH-1 (SB occupies the rightmost column)
    local expected_right=$((WIDTH - 1))
    if [ "$text_left" = "0" ] && [ "$text_right" = "$expected_right" ]; then
        pass "Test 5b: text area occupies cols 0–$((expected_right-1)) (width $expected_right); SB at col $expected_right"
    else
        fail "Test 5b: expected text cols 0–$((expected_right-1)), got left=$text_left right=$text_right"
    fi

    # 5c: visual screen check — first char of a "Line NNN" row must be 'L'
    #     (with right SB the text area starts at screen column 0; with left SB
    #     the SB glyph sits at column 0 and text is displaced to column 1)
    snap "t5-layout"
    local first_char
    first_char=$(capture | grep -m1 "Line 04" | cut -c1)
    if [ "$first_char" = "L" ]; then
        pass "Test 5c: screen column 0 of a text row is 'L' — text starts at left edge, SB is on the right"
    else
        fail "Test 5c: screen column 0 = '${first_char:-?}', expected 'L' (SB may be on wrong side)"
        info "Screen:"; capture
    fi
}

run_test6() {
    header "Test 6: Right SB — click above thumb → page up"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after
    before=$(get_top_line)
    info "Window top before: line ${before:-?}"
    snap "t6-before"

    mouse_click $SB_COL_RIGHT $Y_ABOVE
    sleep 0.6
    snap "t6-after"

    after=$(get_top_line)
    info "Window top after:  line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 6: right SB click above thumb → page UP  ($before → $after)"
    else
        fail "Test 6: expected page UP, got before='$before' after='$after'"
        info "Screen:"; capture
    fi
}

run_test7() {
    header "Test 7: Right SB — click below thumb → page down"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after
    before=$(get_top_line)
    info "Window top before: line ${before:-?}"
    snap "t7-before"

    mouse_click $SB_COL_RIGHT $Y_BELOW
    sleep 0.6
    snap "t7-after"

    after=$(get_top_line)
    info "Window top after:  line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        pass "Test 7: right SB click below thumb → page DOWN ($before → $after)"
    else
        fail "Test 7: expected page DOWN, got before='$before' after='$after'"
        info "Screen:"; capture
    fi
}

run_test8() {
    header "Test 8: Right SB — drag thumb upward (within scroll bar) → live scroll, clean buffer"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after clean
    before=$(get_top_line)
    info "Window top before drag: line ${before:-?}"
    snap "t8-before"

    # Press down on the handle
    mouse_down $SB_COL_RIGHT $Y_THUMB
    sleep 0.35

    # Drag upward, staying in the right scroll bar column
    local row
    for row in 10 9 8 7 6 5 4 3; do
        mouse_move $SB_COL_RIGHT $row
        sleep 0.12
    done

    # Release at xterm y=3 (sb_row=2 → ~9% into buffer ≈ line 10)
    mouse_up $SB_COL_RIGHT 3
    sleep 0.6
    snap "t8-after"

    after=$(get_top_line)
    info "Window top after drag: line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 8a: right SB drag up scrolled buffer UP ($before → $after)"
    else
        fail "Test 8a: expected UP scroll from right SB drag, got before='$before' after='$after'"
        info "Screen:"; capture
    fi

    clean=$(check_buffer_clean)
    info "Buffer check: $clean"
    case "$clean" in
        CLEAN) pass "Test 8b: no escape codes in buffer during right SB drag" ;;
        DIRTY) fail "Test 8b: escape codes found in buffer during right SB drag"; capture ;;
        *)     fail "Test 8b: buffer check returned no result (eval error?)"; capture ;;
    esac
}

run_test9() {
    header "Test 9: Right SB — drag thumb leftward into text area → live scroll by y only, clean buffer"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local before after clean
    before=$(get_top_line)
    info "Window top before drag: line ${before:-?}"
    snap "t9-before"

    # Press down on the handle in the right scroll bar
    mouse_down $SB_COL_RIGHT $Y_THUMB
    sleep 0.35

    # Drag upward AND leftward — x moves from col 80 into the text area.
    # The drag function uses only xterm-mouse-y, so x must NOT matter.
    local pair col row
    for pair in "80 10" "76 9" "72 8" "67 7" "62 6" "57 5" "52 4" "44 3"; do
        col="${pair% *}"
        row="${pair#* }"
        mouse_move "$col" "$row"
        sleep 0.12
    done

    # Release inside the text area (col 44, row 3)
    mouse_up 44 3
    sleep 0.6
    snap "t9-after"

    after=$(get_top_line)
    info "Window top after drag: line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 9a: right SB drag into text area scrolled buffer UP ($before → $after)"
    else
        fail "Test 9a: expected UP scroll from right SB cross-area drag, got before='$before' after='$after'"
        info "Screen:"; capture
    fi

    clean=$(check_buffer_clean)
    info "Buffer check: $clean"
    case "$clean" in
        CLEAN) pass "Test 9b: no escape codes inserted during right SB cross-area drag" ;;
        DIRTY) fail "Test 9b: escape codes found in buffer during right SB cross-area drag"; capture ;;
        *)     fail "Test 9b: buffer check returned no result (eval error?)"; capture ;;
    esac
}

# ── Thumb geometry tests ──────────────────────────────────────────────────────
#
# These tests verify the Lisp implementation of the thumb geometry formula
# (tty-scroll-bar--thumb-geometry) against the C formula in dispnew.c.
#
# All use a 110-line buffer ("Line NNN\n" = 9 chars/line, whole=990, WIN_HT=22).
#
#  Test 10  ws=  1: pos=  0, below=792 → thumb [0,  5)  height= 5 (top)
#  Test 11  ws= 89: pos=792, below=  0 → thumb [17,22)  height= 5 (bottom)
#  Test 12  10-line buffer: portion >= whole    → thumb [0, 22)  height=22 (full)
#  Test 13  ws= 44: pos=387, below=405 → thumb [8, 13)  height= 5
#  Test 14  ws= 23: pos=198, below=594 → thumb [4,  9)  thumb_start=4 (midpoint)
#
# Test 15 verifies grab-point tracking: clicking the middle of the thumb then
# dragging should keep the grab point aligned with the cursor, not snap the
# thumb top to the cursor.
#   ws=44, thumb at sb_rows 8..12 (xterm y 9..13).
#   Click at xterm y=11 (sb_row=10): grab_offset = 10-8 = 2.
#   Drag  to xterm y= 6 (sb_row= 5): effective_row = 5-2 = 3.
#   With grab-point: char = 1 + 3*990/22 = 136 → line 16.
#   Without:         char = 1 + 5*990/22 = 226 → line 26.

# Evaluate tty-scroll-bar--thumb-geometry for *scrolltest* and return
# "START END" (0-indexed; thumb occupies [START,END)).
get_thumb_geometry() {
    local expr
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let ((geom (tty-scroll-bar--thumb-geometry
                  (get-buffer-window "*scrolltest*"))))
       (insert (format "%%d %%d" (car geom) (cdr geom)))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    cat "$RESULT_FILE" 2>/dev/null || echo ""
}

run_test10() {
    header "Test 10: Thumb at top — ws=line 1 → thumb [0, 5)"
    setup_buffer $LINES 1 1

    local geom start end
    geom=$(get_thumb_geometry)
    start=$(echo "$geom" | awk '{print $1}')
    end=$(echo  "$geom" | awk '{print $2}')
    info "Thumb geometry: start=${start:-?} end=${end:-?}"

    if [ "${start:-}" = "0" ]; then
        pass "Test 10a: thumb_start=0 when top of buffer is displayed"
    else
        fail "Test 10a: expected thumb_start=0, got '${start:-empty}'"
    fi
    if [ "${end:-}" = "5" ]; then
        pass "Test 10b: thumb_end=5 when top of buffer is displayed"
    else
        fail "Test 10b: expected thumb_end=5, got '${end:-empty}'"
    fi
}

run_test11() {
    header "Test 11: Thumb at bottom — ws=line 89 → thumb [17, 22)"
    setup_buffer $LINES 89 100

    local geom start end
    geom=$(get_thumb_geometry)
    start=$(echo "$geom" | awk '{print $1}')
    end=$(echo  "$geom" | awk '{print $2}')
    info "Thumb geometry: start=${start:-?} end=${end:-?}"

    if [ "${start:-}" = "17" ]; then
        pass "Test 11a: thumb_start=17 when bottom of buffer is displayed"
    else
        fail "Test 11a: expected thumb_start=17, got '${start:-empty}'"
    fi
    if [ "${end:-}" = "22" ]; then
        pass "Test 11b: thumb_end=22 when bottom of buffer is displayed"
    else
        fail "Test 11b: expected thumb_end=22, got '${end:-empty}'"
    fi
}

run_test12() {
    header "Test 12: Full-height thumb — 10-line buffer fits entirely in window → thumb [0, 22)"
    setup_buffer 10 1 1

    local geom start end
    geom=$(get_thumb_geometry)
    start=$(echo "$geom" | awk '{print $1}')
    end=$(echo  "$geom" | awk '{print $2}')
    info "Thumb geometry: start=${start:-?} end=${end:-?}"

    if [ "${start:-}" = "0" ] && [ "${end:-}" = "22" ]; then
        pass "Test 12: full-height thumb (start=0, end=22) when entire buffer fits in window"
    else
        fail "Test 12: expected thumb [0,22), got [${start:-?},${end:-?})"
    fi
}

run_test13() {
    header "Test 13: Thumb height — ws=line 44 → thumb height=5 rows"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    local geom start end height
    geom=$(get_thumb_geometry)
    start=$(echo "$geom" | awk '{print $1}')
    end=$(echo  "$geom" | awk '{print $2}')
    info "Thumb geometry: start=${start:-?} end=${end:-?}"

    if [ -n "$start" ] && [ -n "$end" ]; then
        height=$((end - start))
        info "Thumb height: $height rows"
        if [ "$height" = "5" ]; then
            pass "Test 13: thumb height=5 rows at ws=line 44 (22 visible lines / 110 total)"
        else
            fail "Test 13: expected thumb height=5, got $height"
        fi
    else
        fail "Test 13: thumb geometry eval returned empty"
    fi
}

run_test14() {
    header "Test 14: Thumb midpoint — ws=line 23 → thumb [4, 9)"
    setup_buffer $LINES 23 30

    local geom start end
    geom=$(get_thumb_geometry)
    start=$(echo "$geom" | awk '{print $1}')
    end=$(echo  "$geom" | awk '{print $2}')
    info "Thumb geometry: start=${start:-?} end=${end:-?}"

    if [ "${start:-}" = "4" ]; then
        pass "Test 14a: thumb_start=4 when ws=line 23 (buffer partially scrolled)"
    else
        fail "Test 14a: expected thumb_start=4, got '${start:-empty}'"
    fi
    if [ "${end:-}" = "9" ]; then
        pass "Test 14b: thumb_end=9 when ws=line 23"
    else
        fail "Test 14b: expected thumb_end=9, got '${end:-empty}'"
    fi
}

run_test15() {
    header "Test 15: Grab-point — clicking thumb at row 11, dragging to row 6 → line ~16, not ~26"
    setup_buffer $LINES $WS_LINE $CUR_LINE
    # Thumb at sb_rows 8..12 (xterm y 9..13).  Click at y=11 (sb_row=10,
    # on the thumb): grab_offset = 10 - thumb_start(8) = 2.
    # Drag to y=6 (sb_row=5): effective = 5-2 = 3 → line 16.
    # Without grab-point: sb_row=5 directly → line 26.

    snap "t15-before"

    mouse_down $SB_COL 11   # press on thumb (grab_offset = 2)
    sleep 0.35
    mouse_move $SB_COL 6    # drag up: effective_row=3 → line 16
    sleep 0.35
    mouse_up   $SB_COL 6
    sleep 0.6
    snap "t15-after"

    local after
    after=$(get_top_line)
    info "Window top after grab-point drag: line ${after:-?}"

    # With grab-point: window-start = line 16.  Without: line 26.
    # Accept ±2 tolerance in case of off-by-one in vertical-motion.
    if [ -n "$after" ] && [ "$after" -ge 14 ] && [ "$after" -le 18 ]; then
        pass "Test 15: grab-point preserved — window-start=line $after (expected ~16, not ~26)"
    else
        fail "Test 15: expected window-start near line 16, got '${after:-?}' (line 26 would indicate no grab-point)"
        info "Screen:"; capture
    fi
}

run_geometry_tests() {
    run_test10
    run_test11
    run_test12
    run_test13
    run_test14
    run_test15
}

run_test16() {
    header "Test 16: Vertical split — border between split windows"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    # Split right and switch the new (right) window to *scratch* so the two
    # sides have visually distinct content.
    _eval_via_mx \
        "(progn (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t16-split"

    # Verify that 2 windows now exist and retrieve the border column
    # (= right edge of the left window, 0-indexed frame column).
    local expr result wcount border_col
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins (window-list))
            (w1   (car wins)))
       (insert (format "%%d %%d"
                       (length wins)
                       (nth 2 (window-edges w1))))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    wcount=$(echo "$result" | awk '{print $1}')
    border_col=$(echo "$result" | awk '{print $2}')
    info "Window count=$wcount, border at frame col=${border_col:-?}"

    if [ "${wcount:-}" = "2" ]; then
        pass "Test 16a: split-window-right created 2 windows"
    else
        fail "Test 16a: expected 2 windows, got '${wcount:-empty}'"
    fi

    # The TTY window divider is rendered as '|' in the content rows (rows 1–22).
    # Buffer content ("Line NNN") and *scratch* content contain no '|', so any
    # '|' on screen must be the vertical window border.
    if capture | head -22 | grep -q '|'; then
        pass "Test 16b: vertical border '|' present between split windows"
    else
        fail "Test 16b: no vertical border '|' found in split window content rows"
        info "Screen:"; capture
    fi

    # Verify '|' appears at the expected border column in at least one content
    # row.  window-edges right edge is exclusive (one past the last column of
    # the window), so the '|' glyph lands at frame col (border_col - 1).
    # tmux capture is 0-indexed strings, so awk substr position = frame_col + 1;
    # for frame col (border_col - 1) that is awk position border_col.
    if [ -n "$border_col" ] && [ "$border_col" -gt 0 ] 2>/dev/null; then
        local col_ok
        col_ok=$(capture | head -22 | \
            awk -v pos="$border_col" '{ if (substr($0, pos, 1) == "|") found++ }
                                      END { print (found > 0) ? "YES" : "NO" }')
        if [ "$col_ok" = "YES" ]; then
            pass "Test 16c: '|' appears at expected border column $((border_col - 1))"
        else
            fail "Test 16c: '|' not found at border column $((border_col - 1))"
            info "Screen:"; capture
        fi
    fi

    # Restore single window.
    _eval_via_mx "(delete-other-windows)"
    sleep 0.3
}

run_test17() {
    header "Test 17: Vertical split with right scroll bar — '|' in SB track column"
    setup_buffer $LINES $WS_LINE $CUR_LINE

    _eval_via_mx \
        "(progn (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t17-split-right-sb"

    local expr result wcount border_col
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins (window-list))
            (w1   (car wins)))
       (insert (format "%%d %%d"
                       (length wins)
                       (nth 2 (window-edges w1))))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    wcount=$(echo "$result" | awk '{print $1}')
    border_col=$(echo "$result" | awk '{print $2}')
    info "Window count=$wcount, right SB border at frame col=${border_col:-?}"

    if [ "${wcount:-}" = "2" ]; then
        pass "Test 17a: split-window-right created 2 windows (right SB)"
    else
        fail "Test 17a: expected 2 windows, got '${wcount:-empty}'"
    fi

    # With right scroll bars the '|' is rendered inside the right SB column
    # of the left window (track rows only).  buffer content and *scratch* have
    # no '|', so any '|' in content rows comes from the SB track.
    if capture | head -22 | grep -q '|'; then
        pass "Test 17b: vertical border '|' present in right-SB split"
    else
        fail "Test 17b: no '|' found in right-SB split content rows"
        info "Screen:"; capture
    fi

    # The right SB occupies the last column of the left window, at frame col
    # border_col - 1.  awk position = border_col.
    if [ -n "$border_col" ] && [ "$border_col" -gt 0 ] 2>/dev/null; then
        local col_ok
        col_ok=$(capture | head -22 | \
            awk -v pos="$border_col" '{ if (substr($0, pos, 1) == "|") found++ }
                                      END { print (found > 0) ? "YES" : "NO" }')
        if [ "$col_ok" = "YES" ]; then
            pass "Test 17c: '|' appears at right SB border column $((border_col - 1))"
        else
            fail "Test 17c: '|' not found at right SB border column $((border_col - 1))"
            info "Screen:"; capture
        fi
    fi

    _eval_via_mx "(delete-other-windows)"
    sleep 0.3
}

run_test18() {
    # Test with RIGHT scroll bars + window-divider-mode.  This is the
    # problematic combination: with a short buffer the right SB has a
    # full-height thumb (no track rows), so a naive "only track rows get |"
    # approach shows nothing.  We must see '|' even with a full-height thumb.
    header "Test 18: window-divider-mode + right scroll bars — both SB and '|' present"
    set_scroll_bar_side right
    # Use *scratch* (short buffer → full-height thumb) so the test catches
    # the full-thumb regression.
    _eval_via_mx \
        "(progn (window-divider-mode 1) (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t18-divider-right-split"

    # 18a: right scroll bar must be active.
    local sb_side
    _eval_via_mx \
        "(with-temp-file \"$RESULT_FILE\" (insert (format \"%s\" (frame-parameter nil 'vertical-scroll-bars))))"
    sb_side=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    info "Scroll bar side with window-divider-mode: ${sb_side:-none}"
    if [ "${sb_side:-}" = "right" ]; then
        pass "Test 18a: right scroll bar active alongside window-divider-mode"
    else
        fail "Test 18a: expected right scroll bar, got '${sb_side:-empty}'"
    fi

    # 18b: '|' must be visible in content rows despite full-height thumb.
    if capture | head -22 | grep -q '|'; then
        pass "Test 18b: '|' border present with right SB + window-divider-mode (full-height thumb)"
    else
        fail "Test 18b: no '|' border found (full-height thumb regression)"
        info "Screen:"; capture
    fi

    # 18c: '|' at the right SB column (right edge of left window - 1).
    local result wcount border_col expr
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins (window-list))
            (w1   (car wins)))
       (insert (format "%%d %%d"
                       (length wins)
                       (nth 2 (window-edges w1))))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    wcount=$(echo "$result" | awk '{print $1}')
    border_col=$(echo "$result" | awk '{print $2}')
    info "Window count=$wcount, right SB border col=${border_col:-?}"

    if [ -n "$border_col" ] && [ "$border_col" -gt 0 ] 2>/dev/null; then
        local col_ok
        col_ok=$(capture | head -22 | \
            awk -v pos="$border_col" '{ if (substr($0, pos, 1) == "|") found++ }
                                      END { print (found > 0) ? "YES" : "NO" }')
        if [ "$col_ok" = "YES" ]; then
            pass "Test 18c: '|' at right SB border column $((border_col - 1)) with window-divider-mode"
        else
            fail "Test 18c: '|' not at right SB border column $((border_col - 1))"
            info "Screen:"; capture
        fi
    fi

    # Clean up: disable window-divider-mode and restore left scroll bars.
    _eval_via_mx "(progn (window-divider-mode -1) (delete-other-windows))"
    sleep 0.3
    set_scroll_bar_side left
}

run_test19() {
    # Verify that scrolling the left window after a split-window-right does not
    # alter the right window's scroll bar geometry.  The right window shows
    # *scratch* (short buffer → full-height thumb: start=0, end=WIN_HT).
    # Scrolling the left window triggers a full redisplay; the bug was that
    # tty_set_vertical_scroll_bar wrote incorrect data for the right window
    # during that redisplay, visually corrupting its scroll bar.
    header "Test 19: Scrolling left window does not modify right window's scroll bar"
    set_scroll_bar_side right
    setup_buffer $LINES $WS_LINE $CUR_LINE

    # Left=*scrolltest* (110 lines), right=*scratch* (short, full-height thumb).
    _eval_via_mx \
        "(progn (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t19-initial"

    # Capture the right window's thumb geometry before scrolling the left window.
    # window-list starts from the selected window (left/*scrolltest*), so
    # (cadr wins) is the right window (*scratch*).
    local expr geom_before geom_after
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins     (window-list))
            (right-w  (cadr wins))
            (geom     (tty-scroll-bar--thumb-geometry right-w)))
       (insert (format "%%d %%d" (car geom) (cdr geom)))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    geom_before=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    info "Right window thumb geometry before scroll: '${geom_before:-empty}'"

    # Scroll the left window (currently selected) down then up, forcing
    # multiple redisplay cycles that should update only the left SB.
    _eval_via_mx "(progn (scroll-up 10) (scroll-down 5))"
    sleep 0.5
    snap "t19-after-scroll"

    # Capture right window geometry after scrolling.
    _eval_via_mx "$expr"
    geom_after=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    info "Right window thumb geometry after scroll:  '${geom_after:-empty}'"

    if [ -n "$geom_before" ] && [ "$geom_before" = "$geom_after" ]; then
        pass "Test 19: right window scroll bar unchanged after scrolling left window (geometry='$geom_before')"
    else
        fail "Test 19: right window scroll bar changed (before='${geom_before:-empty}' after='${geom_after:-empty}')"
        info "Screen:"; capture
    fi

    _eval_via_mx "(delete-other-windows)"
    sleep 0.3
    set_scroll_bar_side left
}

run_test20() {
    # Verify that adding lines to the left window does not corrupt the
    # right window's scroll bar geometry.  The right window shows *scratch*
    # (short buffer → full-height thumb: start=0, end=WIN_HT).  Adding lines
    # to the left buffer triggers redisplay for the left window; the right
    # window's scroll bar should be unaffected.
    header "Test 20: Adding lines to left window does not modify right window's scroll bar"
    set_scroll_bar_side right
    setup_buffer $LINES $WS_LINE $CUR_LINE

    _eval_via_mx \
        "(progn (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t20-initial"

    # Capture right window thumb geometry before modifying left buffer.
    local expr geom_before geom_after
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins    (window-list))
            (right-w (cadr wins))
            (geom    (tty-scroll-bar--thumb-geometry right-w)))
       (insert (format "%%d %%d" (car geom) (cdr geom)))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    geom_before=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    info "Right window thumb before adding lines: '${geom_before:-empty}'"

    # Add 100 lines to *scrolltest* in the left window (left window stays selected).
    _eval_via_mx \
        "(with-current-buffer \"*scrolltest*\" (goto-char (point-max)) (dotimes (i 100) (insert (format \"Extra line %d\\n\" i))))"
    sleep 0.5
    snap "t20-after-insert"

    # Capture right window thumb geometry after modification.
    _eval_via_mx "$expr"
    geom_after=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    info "Right window thumb after adding lines:  '${geom_after:-empty}'"

    if [ -n "$geom_before" ] && [ "$geom_before" = "$geom_after" ]; then
        pass "Test 20: right window scroll bar unchanged after adding 100 lines to left window (geometry='$geom_before')"
    else
        fail "Test 20: right window scroll bar changed (before='${geom_before:-empty}' after='${geom_after:-empty}')"
        info "Screen:"; capture
    fi

    _eval_via_mx "(delete-other-windows)"
    sleep 0.3
    set_scroll_bar_side left
}

run_test21() {
    # Verify that dragging the '|' border between split windows resizes them.
    # With the right scroll bar layout [content][SB][|], the '|' is at the last
    # column of the left window.  Clicking and dragging it should trigger
    # mouse-drag-vertical-line → adjust-window-trailing-edge.
    header "Test 21: Drag '|' border right — left window grows"
    set_scroll_bar_side right
    setup_buffer $LINES $WS_LINE $CUR_LINE

    _eval_via_mx \
        "(progn (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t21-initial"

    # Get initial geometry: right-edge of left window and its total-width.
    # The '|' border is at frame col (right-edge - 1); xterm col = right-edge.
    local expr result wcount right_edge initial_width
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins (window-list))
            (w1   (car wins)))
       (insert (format "%%d %%d %%d"
                       (length wins)
                       (nth 2 (window-edges w1))
                       (window-total-width w1)))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    wcount=$(echo "$result" | awk '{print $1}')
    right_edge=$(echo "$result" | awk '{print $2}')
    initial_width=$(echo "$result" | awk '{print $3}')
    info "Windows=$wcount, right-edge=$right_edge, initial width=$initial_width"

    # xterm col of '|' = right-edge (frame col right-edge-1 + 1).
    local border_xterm="$right_edge"
    local target_xterm=$((border_xterm + 5))

    # Drag the border 5 columns to the right.
    mouse_down "$border_xterm" 5
    sleep 0.35
    local col
    for col in $(seq $((border_xterm + 1)) "$target_xterm"); do
        mouse_move "$col" 5
        sleep 0.12
    done
    mouse_up "$target_xterm" 5
    sleep 0.6
    snap "t21-after-drag"

    # Get new width.
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    local new_width
    new_width=$(echo "$result" | awk '{print $3}')
    info "Left window width after drag: $new_width (was $initial_width)"

    if [ -n "$initial_width" ] && [ -n "$new_width" ] && [ "$new_width" -gt "$initial_width" ]; then
        pass "Test 21: dragging '|' border right grew left window ($initial_width → $new_width cols)"
    else
        fail "Test 21: expected width increase, got initial='${initial_width:-?}' after='${new_width:-?}'"
        info "Screen:"; capture
    fi

    _eval_via_mx "(delete-other-windows)"
    sleep 0.3
    set_scroll_bar_side left
}

run_test22() {
    # Verify that with window-divider-mode the scroll bar column (one column
    # left of the '|' border) correctly scrolls the window rather than acting
    # as a window divider drag target.  This was broken before the
    # xterm-mouse--tty-scroll-bar-window fix: clicking at the SB column
    # generated a vertical-line event (window resize) instead of a
    # vertical-scroll-bar event (scroll).
    header "Test 22: window-divider-mode — SB click scrolls (not resizes window)"
    set_scroll_bar_side right
    setup_buffer $LINES $WS_LINE $CUR_LINE

    _eval_via_mx \
        "(progn (window-divider-mode 1) (split-window-right) (other-window 1) (switch-to-buffer \"*scratch*\") (other-window 1))"
    sleep 0.5
    snap "t22-initial"

    # The left window's SB is at frame col (right-edge - 2); xterm col = right-edge - 1.
    local expr result right_edge initial_width
    expr=$(printf \
'(condition-case nil
   (with-temp-file "%s"
     (let* ((wins (window-list))
            (w1   (car wins)))
       (insert (format "%%d %%d"
                       (nth 2 (window-edges w1))
                       (window-total-width w1)))))
   (error nil))' \
        "$RESULT_FILE")
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    right_edge=$(echo "$result" | awk '{print $1}')
    initial_width=$(echo "$result" | awk '{print $2}')
    local sb_xterm=$((right_edge - 1))  # xterm col of SB (frame col right-edge-2)
    info "Right-edge=$right_edge, SB at xterm col=$sb_xterm, initial width=$initial_width"

    # Record window-start before clicking.
    local before after
    before=$(get_top_line)
    info "Window top before SB click: line ${before:-?}"

    # Click above the thumb in the left window's scroll bar.
    mouse_click "$sb_xterm" $Y_ABOVE
    sleep 0.6
    snap "t22-after-click"

    # 22a: window scrolled (page up), confirming it was a scroll bar click.
    after=$(get_top_line)
    info "Window top after SB click: line ${after:-?}"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
        pass "Test 22a: SB click scrolled window up ($before → $after) — not a divider drag"
    else
        fail "Test 22a: expected page UP scroll, got before='$before' after='$after'"
        info "Screen:"; capture
    fi

    # 22b: window width unchanged (no resize happened).
    _eval_via_mx "$expr"
    result=$(cat "$RESULT_FILE" 2>/dev/null || echo "")
    local after_width
    after_width=$(echo "$result" | awk '{print $2}')
    if [ -n "$initial_width" ] && [ "$after_width" = "$initial_width" ]; then
        pass "Test 22b: window width unchanged ($initial_width) — no accidental resize"
    else
        fail "Test 22b: window width changed (was $initial_width, now ${after_width:-?}) — SB acted as divider"
        info "Screen:"; capture
    fi

    _eval_via_mx "(progn (window-divider-mode -1) (delete-other-windows))"
    sleep 0.3
    set_scroll_bar_side left
}

run_right_tests() {
    set_scroll_bar_side right
    run_test5
    run_test6
    run_test7
    run_test8
    run_test9
    run_test17
    # Restore left scroll bar for any subsequent interactive use.
    set_scroll_bar_side left
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo "════════════════════════════════════════════"
    printf "  RESULTS: %d passed, %d failed\n" "$PASS" "$FAIL"
    echo "  Pane log:   $PANE_LOG"
    echo "  Server log: $LOGDIR/tmux-server-*.log"
    echo "════════════════════════════════════════════"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────
case "${1:-run}" in
    run)
        start_session
        run_test0
        run_test1
        run_test2
        run_test3
        run_test4
        run_geometry_tests
        run_test16
        run_test18
        run_test19
        run_test20
        run_test21
        run_test22
        run_right_tests
        print_summary
        tmux -S "$SOCKET" kill-server 2>/dev/null || true
        [ "$FAIL" -eq 0 ]
        ;;
    attach)
        tmux -S "$SOCKET" attach -t "$SESSION"
        ;;
    cap|capture)
        capture
        ;;
    kill)
        tmux -S "$SOCKET" kill-server 2>/dev/null || true
        echo "Session killed."
        ;;
    send)
        shift
        send_key "$@" ""
        sleep 0.3
        capture
        ;;
    *)
        echo "Usage: $0 {run|attach|cap|send KEYS|kill}"
        exit 1
        ;;
esac
