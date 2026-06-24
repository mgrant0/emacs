;;; scroll-bar-tty-tests.el --- Tests for TTY scroll bar  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'scroll-bar)
(require 'xt-mouse)

;;;; Pure-arithmetic tests (no window required).

(ert-deftest tty-sb-drag-formula-top ()
  "sb-row=0 maps to point-min."
  (let* ((point-min 1) (size 900) (win-ht 20))
    (should (= (+ point-min (/ (* 0 size) (max 1 (1- win-ht))))
               point-min))))

(ert-deftest tty-sb-drag-formula-bottom ()
  "sb-row=(win-ht-1) maps to point-max."
  (let* ((point-min 1) (size 900) (win-ht 20) (sb-row (1- win-ht)))
    (should (= (+ point-min (/ (* sb-row size) (max 1 (1- win-ht))))
               (+ point-min size)))))

(ert-deftest tty-sb-drag-formula-win-ht-1 ()
  "With win-ht=1 the denominator clamps to 1 and any drag goes to point-min."
  (let* ((point-min 1) (size 900) (win-ht 1))
    (should (= (+ point-min (/ (* 0 size) (max 1 (1- win-ht))))
               point-min))))

;;;; Window-based tests.
;;
;; These tests need a window that shows a real buffer.  We use
;; `switch-to-buffer' inside `save-window-excursion' so that the selected
;; window is restored after each test.

(defun tty-sb-test--fill-buffer (buf n-lines)
  "Fill BUF with N-LINES lines of the form \"line NNNN\\n\"."
  (with-current-buffer buf
    (dotimes (i n-lines)
      (insert (format "line %4d\n" i)))))

(defmacro tty-sb-test--with-window (buf-var &rest body)
  "Run BODY with BUF-VAR bound to a temp buffer shown in the selected window.
The buffer has 200 lines.  The window configuration is restored afterward."
  (declare (indent 1))
  (let ((gbuf (gensym "buf")))
    `(let ((,gbuf (generate-new-buffer " *tty-sb-test*")))
       (unwind-protect
           (save-window-excursion
             (tty-sb-test--fill-buffer ,gbuf 200)
             (switch-to-buffer ,gbuf)
             (let ((,buf-var ,gbuf))
               ,@body))
         (kill-buffer ,gbuf)))))

(defun tty-sb-test--drag-to (win sb-row)
  "Apply the tty-scroll-bar-drag formula for SB-ROW in WIN.
Sets window-start as the real drag handler would."
  (let* ((win-ht (window-body-height win))
         (size   (with-current-buffer (window-buffer win)
                   (- (point-max) (point-min)))))
    (with-current-buffer (window-buffer win)
      (goto-char (+ (point-min)
                    (/ (* sb-row size) (max 1 (1- win-ht)))))
      (vertical-motion 0 win)
      (set-window-start win (point)))))

(ert-deftest tty-sb-thumb-geometry-at-bottom ()
  "After dragging to the bottom, tty-scroll-bar--thumb-geometry returns
a valid 1-row thumb at or near the lowest scroll-bar row."
  (tty-sb-test--with-window _buf
    (let* ((win    (selected-window))
           (win-ht (window-body-height win)))
      (tty-sb-test--drag-to win (1- win-ht))
      (let* ((geom (tty-scroll-bar--thumb-geometry win))
             (ts   (car geom))
             (te   (cdr geom)))
        ;; thumb range must be valid
        (should (< ts te))
        ;; thumb must be at the bottom of the scroll bar
        (should (>= ts (- win-ht 2)))
        (should (<= te win-ht))))))

(ert-deftest tty-sb-classifier-agrees-with-geometry-at-bottom ()
  "After dragging to the bottom, tty-scroll-bar--part returns
\\='handle for the row that tty-scroll-bar--thumb-geometry reports as the
thumb start.

This is the invariant that allows a second drag to be initiated: if the
classifier disagrees with the renderer it returns \\='above-handle or
\\='below-handle instead of \\='handle, and tty-scroll-bar-down-mouse-1
refuses to start the drag."
  (tty-sb-test--with-window _buf
    (let* ((win     (selected-window))
           (win-ht  (window-body-height win))
           (win-top (window-top-line win)))
      (tty-sb-test--drag-to win (1- win-ht))
      (let* ((geom (tty-scroll-bar--thumb-geometry win))
             (ts   (car geom)))
        ;; Clicking the thumb's top row must be classified as 'handle.
        (should (eq (tty-scroll-bar--part win (+ win-top ts))
                    'handle))
        ;; The bottommost scroll-bar row must also be 'handle (the thumb
        ;; is 1 row tall and sits at the bottom when at end of buffer).
        (should (eq (tty-scroll-bar--part win (+ win-top (1- win-ht)))
                    'handle))))))

(ert-deftest tty-sb-drag-up-after-bottom ()
  "After dragging to the bottom, dragging up to the midpoint scrolls the
buffer up and moves the scroll-bar thumb up."
  (tty-sb-test--with-window _buf
    (let* ((win    (selected-window))
           (win-ht (window-body-height win)))
      ;; Step 1: drag to bottom.
      (tty-sb-test--drag-to win (1- win-ht))
      (let ((start-after-bottom (window-start win)))
        ;; Thumb must be at the bottom.
        (let* ((geom (tty-scroll-bar--thumb-geometry win))
               (ts   (car geom)))
          (should (>= ts (- win-ht 2))))
        ;; Step 2: drag to the midpoint.
        (let ((mid-row (/ (1- win-ht) 2)))
          (tty-sb-test--drag-to win mid-row)
          ;; window-start must have moved up from the bottom position.
          (should (< (window-start win) start-after-bottom))
          ;; Thumb must be near the middle of the scroll bar.
          (let* ((geom (tty-scroll-bar--thumb-geometry win))
                 (ts   (car geom)))
            (should (<= ts (/ win-ht 2)))))))))

;;;; Geometry oracle: header-line + tty-scroll-bar-thumb-rows (no child emacs).
;;
;; tty-scroll-bar-thumb-rows (src/dispnew.c) uses the same top_skip / sb_rows
;; formula as the TTY renderer.  These tests verify that formula accounts for a
;; header-line correctly, even without a real TTY frame.

(ert-deftest tty-sb-geometry-sb-height-with-header ()
  "With a header-line, sb_rows equals window-body-height.
This confirms top_skip=1 is included so the scroll-bar body starts on the
first body row, immediately below the header."
  (tty-sb-test--with-window buf
    (let* ((win (selected-window)))
      ;; Set a header-line on the test buffer.
      (with-current-buffer buf
        (setq header-line-format "=== TEST HEADER ==="))
      ;; Force the iterator to notice the header (needed in some builds).
      (set-window-buffer win buf)
      (let* ((body-ht     (window-body-height win))
             (geom-top    (tty-scroll-bar--thumb-geometry win))
             (thumb-start (car geom-top)))
        ;; The thumb is within the SB body region [0, sb_rows).
        ;; sb_rows = body_ht (mode-line and header-line excluded).
        ;; At point-min the thumb must start at row 0 (first SB body row).
        (should (= thumb-start 0))
        ;; Thumb end must be at most body-ht (SB is not taller than the body).
        (should (<= (cdr geom-top) body-ht))))))

(ert-deftest tty-sb-geometry-thumb-within-sb-rows ()
  "After dragging to the bottom with a header-line, the thumb stays within sb_rows.
Confirms that the top_skip used by tty-scroll-bar-thumb-rows does not
accidentally inflate sb_rows by ignoring the header-line."
  (tty-sb-test--with-window buf
    (let* ((win (selected-window)))
      (with-current-buffer buf
        (setq header-line-format "=== TEST HEADER ==="))
      (set-window-buffer win buf)
      (let* ((body-ht (window-body-height win)))
        ;; Drag to the very bottom.
        (tty-sb-test--drag-to win (1- body-ht))
        (let* ((geom (tty-scroll-bar--thumb-geometry win))
               (ts   (car geom))
               (te   (cdr geom)))
          ;; Thumb range must be valid.
          (should (< ts te))
          ;; Thumb must be entirely within [0, body-ht) — i.e., the SB body.
          (should (>= ts 0))
          (should (<= te body-ht)))))))

;;;; Integration tests: child emacs -Q -nw with header-line buffers.
;;
;; Launches a child emacs -nw through term.el so that its TTY output (with ANSI
;; control sequences interpreted by `term-emulate-terminal') is rendered into a
;; term buffer.  Scrapes per-row strings from that buffer and checks the actual
;; cells at the frame edges:
;;   (A) The header-line row spans the full frame width including the scroll-bar
;;       column.  Its first and last characters must survive.
;;   (B) The scroll-bar body begins on the first body row, not on the
;;       header-line row, and spans every body row.
;;
;; The child uses a portable 200-line buffer with header-line-format set, so
;; the test does not depend on installed Info files.
;;
;; Skipped on MS Windows / MS-DOS (no usable pty).

(defun tty-sb-test--child-screen-rows (width height setup-form
                                       &optional sentinel timeout)
  "Run child emacs -Q -nw with SETUP-FORM; return per-row screen strings.
WIDTH and HEIGHT fix the pty size.  SENTINEL is a string to wait for in the
child's output (default \"READY\"); TIMEOUT is the maximum seconds to wait
(default 10).  Returns a list of HEIGHT strings, each up to WIDTH characters,
with `font-lock-face' text properties as written by `term-emulate-terminal'.
Signals an ERT failure if the sentinel is not found within TIMEOUT seconds."
  (require 'term)
  (with-temp-buffer
    (term-mode)
    ;; Prevent term.el from overriding the fixed pty size we set below.
    (remove-function (local 'window-adjust-process-window-size-function)
                     'term-maybe-reset-size)
    (let* ((emacs-bin (expand-file-name invocation-name invocation-directory))
           (proc (get-buffer-process
                  (term-exec (current-buffer) "tty-sb-child"
                             emacs-bin nil
                             (list "-Q" "-nw"
                                   "--eval"
                                   (prin1-to-string setup-form))))))
      (term-char-mode)
      (setq term-width  width
            term-height height)
      (set-process-query-on-exit-flag proc nil)
      (set-process-window-size proc height width)
      (unwind-protect
          (let* ((target   (or sentinel "READY"))
                 (deadline (+ (float-time) (or timeout 10.0)))
                 sentinel-found)
            ;; Poll until sentinel appears or timeout.
            (while (and (not sentinel-found) (< (float-time) deadline))
              (accept-process-output proc 0.3)
              (setq sentinel-found
                    (string-search target (buffer-string))))
            (unless sentinel-found
              (ert-fail
               (format "tty-sb-test: child emacs didn't produce %S in %.0fs"
                       target (or timeout 10.0))))
            ;; Let the last frame redisplay finish.
            (accept-process-output proc 0.5)
            ;; Extract per-row strings with text properties.
            ;; Start at term-home-marker, not (point-min): when eterm-color uses
            ;; the alternate screen (smcup=\E[47h), term-switch-to-alternate-sub-buffer
            ;; inserts a \n before the alternate-screen content and advances
            ;; term-home-marker past it.  (point-min) is that blank \n; the
            ;; actual frame rows start at term-home-marker.
            (save-excursion
              (goto-char term-home-marker)
              (let (rows)
                (dotimes (_ height)
                  (let* ((bol (point))
                         ;; Don't include the newline or overshoot.
                         (eol (min (+ bol width) (line-end-position))))
                    (push (buffer-substring bol eol) rows))
                  (forward-line 1))
                (nreverse rows))))
        (when (process-live-p proc)
          (delete-process proc))))))

(defun tty-sb-test--header-layout-case (side &optional scroll)
  "Check TTY scroll-bar/header layout for scroll-bar SIDE.
When SCROLL is non-nil, scroll the child buffer before scraping the screen."
  (when (memq system-type '(windows-nt ms-dos))
    (ert-skip "No usable pty on this system"))
  (require 'term)
  (let* ((width  80)
         (height 24)
         (body-line (concat (make-string (* 2 width) ?B) "\n"))
         (setup-form
          `(progn
             (setq inhibit-startup-screen t)
             (menu-bar-mode -1)
             (set-scroll-bar-mode ',side)
             (with-current-buffer (get-buffer-create " *tty-sb-itest*")
               (setq mode-line-format "MODELINE"
                     truncate-lines t)
               (dotimes (_ 200)
                 (insert ,body-line))
               (switch-to-buffer (current-buffer))
               (goto-char (point-min))
               (setq header-line-format
                     (concat "L" (make-string (- (window-total-width) 2) ?H)
                             "R")))
             ,@(when scroll
                 '((dotimes (_ 5) (scroll-up-command))))
             (redisplay t)
             (message "READY")))
         (rows (tty-sb-test--child-screen-rows width height setup-form))
         (header-row (nth 0 rows))
         (actual-width (length header-row))
         (mode-line-idx
          (cl-position-if (lambda (r)
                            (string-match-p "MODELINE" r))
                          rows :start 1))
         (body-count (and mode-line-idx (- mode-line-idx 1)))
         (body-rows (and mode-line-idx
                         (cl-subseq rows 1 mode-line-idx)))
         (leftp (eq side 'left))
         (sb-col (if leftp 0 (1- actual-width)))
         (text-col (if leftp 1 (- actual-width 2)))
         (sb-body-count 0))
    (should (>= (length rows) height))
    (should (> actual-width 2))
    (ert-info ((format "%S header row: %S" side header-row))
      (should (eql (aref header-row 0) ?L))
      (should (eql (aref header-row (1- actual-width)) ?R)))
    (ert-info ((format "%S mode-line at row %S" side mode-line-idx))
      (should (and mode-line-idx (> body-count 0)))
      (should body-rows))
    (dolist (row body-rows)
      (when (and (> (length row) sb-col)
                 (> (length row) text-col)
                 (eql (aref row sb-col) ? )
                 (not (eql (aref row text-col) ? )))
        (setq sb-body-count (1+ sb-body-count))))
    (ert-info ((format "%S body-count=%S sb-body-count=%d"
                       side body-count sb-body-count))
      (should (= sb-body-count body-count)))))

(defun tty-sb-test--read-geom (rows)
  "Read the first printed GEOM list from ROWS."
  (let ((line (cl-find-if (lambda (row)
                            (string-match "GEOM " (substring-no-properties row)))
                          rows)))
    (unless line
      (ert-fail (format "No GEOM row in child screen: %S" rows)))
    (let ((text (substring-no-properties line)))
      (string-match "GEOM " text)
      (read (substring text (match-end 0))))))

(defun tty-sb-test--frame-width-case (side scroll-bar-width)
  "Check TTY frame geometry for scroll-bar SIDE and SCROLL-BAR-WIDTH.
This verifies the invariant that prevents terminal wrapping/banding:
enabling scroll bars keeps the frame total width equal to the
no-scrollbar terminal width, and reduces the text width by the number
of TTY scroll-bar columns."
  (when (memq system-type '(windows-nt ms-dos))
    (ert-skip "No usable pty on this system"))
  (let* ((width 90)
         (height 24)
         (setup-form
          `(progn
             (setq inhibit-startup-screen t)
             (menu-bar-mode -1)
             (with-current-buffer (get-buffer-create " *tty-sb-geom*")
               (setq mode-line-format "MODELINE"
                     truncate-lines t)
               (erase-buffer)
               (dotimes (i 200)
                 (insert (format "line %03d %s\n" i
                                 ,(make-string (* 2 width) ?x))))
               (switch-to-buffer (current-buffer))
               (goto-char (point-min)))
             (redisplay t)
             (let ((base-total (frame-total-cols))
                   (base-width (frame-width)))
               (set-scroll-bar-mode ',side)
               (modify-frame-parameters
                nil (list (cons 'scroll-bar-width ,scroll-bar-width)))
               (redisplay t)
               (let* ((win (selected-window))
                      (bars (window-scroll-bars win))
                      (geom (list base-total
                                  base-width
                                  (frame-total-cols)
                                  (frame-width)
                                  (window-total-width
                                   (frame-root-window))
                                  (window-total-width win)
                                  (window-body-width win)
                                  (nth 1 bars)
                                  (frame-parameter
                                   nil 'vertical-scroll-bars)
                                  (frame-parameter
                                   nil 'scroll-bar-width))))
                 (with-current-buffer (window-buffer win)
                   (erase-buffer)
                   (insert "GEOM " (prin1-to-string geom) "\n")
                   (goto-char (point-min)))))
             (redisplay t)
             (message "READY")))
         (rows (tty-sb-test--child-screen-rows width height setup-form))
         (geom (tty-sb-test--read-geom rows))
         (base-total (nth 0 geom))
         (base-width (nth 1 geom))
         (frame-total (nth 2 geom))
         (frame-width (nth 3 geom))
         (root-total (nth 4 geom))
         (win-total (nth 5 geom))
         (win-body (nth 6 geom))
         (sb-cols (nth 7 geom))
         (actual-side (nth 8 geom))
         (actual-scroll-bar-width (nth 9 geom)))
    (ert-info ((format "%S width=%d geometry: %S"
                       side scroll-bar-width geom))
      (should (= base-total base-width))
      (should (= frame-total base-total))
      (should (= root-total base-total))
      (should (= win-total base-total))
      (should (= sb-cols scroll-bar-width))
      (should (= frame-width (- base-total sb-cols)))
      (should (= win-body (- base-total sb-cols)))
      (should (eq actual-side side))
      (should (= actual-scroll-bar-width scroll-bar-width)))))

(defun tty-sb-test--side-width-change-case ()
  "Check TTY scroll-bar geometry after changing side and width repeatedly."
  (when (memq system-type '(windows-nt ms-dos))
    (ert-skip "No usable pty on this system"))
  (let* ((width 90)
         (height 24)
         (setup-form
          `(progn
             (require 'cl-lib)
             (setq inhibit-startup-screen t)
             (menu-bar-mode -1)
             (with-current-buffer (get-buffer-create " *tty-sb-side-width*")
               (setq mode-line-format "MODELINE"
                     truncate-lines t)
               (erase-buffer)
               (dotimes (i 200)
                 (insert (format "line %03d %s\n" i
                                 ,(make-string (* 2 width) ?x))))
               (switch-to-buffer (current-buffer))
               (goto-char (point-min)))
             (redisplay t)
             (let ((base-total (frame-total-cols))
                   snapshots)
               (cl-labels
                   ((snap
                     (side width)
                     (set-scroll-bar-mode side)
                     (modify-frame-parameters
                      nil (list (cons 'scroll-bar-width width)))
                     (redisplay t)
                     (let* ((win (selected-window))
                            (bars (window-scroll-bars win))
                            (inside (window-inside-edges win)))
                       (push (list side
                                   width
                                   (frame-total-cols)
                                   (frame-width)
                                   (window-body-width win)
                                   (nth 1 bars)
                                   (nth 0 inside))
                             snapshots))))
                 (snap 'right 3)
                 (snap 'left 2)
                 (snap 'right 1))
               (with-current-buffer (window-buffer (selected-window))
                 (erase-buffer)
                 (insert "GEOM " (prin1-to-string
                                  (cons base-total
                                        (nreverse snapshots)))
                         "\n")
                 (goto-char (point-min))))
             (redisplay t)
             (message "READY")))
         (rows (tty-sb-test--child-screen-rows width height setup-form))
         (geom (tty-sb-test--read-geom rows))
         (base-total (car geom))
         (snapshots (cdr geom)))
    (ert-info ((format "side/width geometry: %S" geom))
      (should (= (length snapshots) 3))
      (dolist (snap snapshots)
        (let ((side (nth 0 snap))
              (requested-width (nth 1 snap))
              (frame-total (nth 2 snap))
              (frame-width (nth 3 snap))
              (win-body (nth 4 snap))
              (sb-cols (nth 5 snap))
              (inside-left (nth 6 snap)))
          (should (= frame-total base-total))
          (should (= sb-cols requested-width))
          (should (= frame-width (- base-total sb-cols)))
          (should (= win-body (- base-total sb-cols)))
          (should (= inside-left (if (eq side 'left) sb-cols 0))))))
      (let ((final (car (last snapshots))))
        (should (eq (nth 0 final) 'right))
        (should (= (nth 1 final) 1))
        (should (= (nth 6 final) 0)))))

(ert-deftest tty-sb-integration-header-full-width-left ()
  "Left scroll bar: the header spans the frame, body rows reserve column 0."
  (tty-sb-test--header-layout-case 'left))

(ert-deftest tty-sb-integration-header-scroll-no-clip ()
  "Left scroll bar after scrolling: the scroll bar still spans body rows only."
  (tty-sb-test--header-layout-case 'left t))

(ert-deftest tty-sb-integration-header-full-width-right ()
  "Right scroll bar: the header spans the frame, body rows reserve column 79."
  (tty-sb-test--header-layout-case 'right))

(ert-deftest tty-sb-integration-frame-width-right ()
  "Right scroll bar: frame text width shrinks within the terminal width."
  (tty-sb-test--frame-width-case 'right 1))

(ert-deftest tty-sb-integration-frame-width-left ()
  "Left scroll bar: frame text width shrinks within the terminal width."
  (tty-sb-test--frame-width-case 'left 1))

(ert-deftest tty-sb-integration-frame-width-wide-scroll-bar ()
  "Wide scroll bar: text width shrinks by all scroll-bar columns."
  (tty-sb-test--frame-width-case 'right 3))

(ert-deftest tty-sb-integration-side-width-changes ()
  "Changing scroll-bar side and width repeatedly preserves TTY geometry."
  (tty-sb-test--side-width-change-case))

(provide 'scroll-bar-tty-tests)

;;; scroll-bar-tty-tests.el ends here
