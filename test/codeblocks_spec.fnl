;; Code block padding is screen space, not source whitespace. Verify the
;; rendered rows and that cursor movement does not change their placement.

(local h (require :helpers))
(local mada (require :mada))

(fn trim [s]
  (pick-values 1 (s:gsub "%s+$" "")))

(fn scratch [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn visible_rows [n]
  (let [rows []]
    (for [r 1 n]
      (table.insert rows (trim (h.screen_row r 40))))
    rows))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn test-one-line-fenced []
  (mada.setup {:anti_conceal false :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (set vim.o.lines 30)
  (let [buf (scratch [:before "```lua" "x = 1" "```" :after])]
    (mada.render buf)
    (let [rows (visible_rows 12)
          code-screen-row (. (vim.fn.screenpos 0 3 1) :row)]
      (check (> code-screen-row 1) "code content has a visible screen row")
      (h.eq "" (. rows (- code-screen-row 1)) "top padding is blank")
      (h.eq " x = 1" (. rows code-screen-row) "one space before code text")
      (h.eq "" (. rows (+ code-screen-row 1)) "bottom padding is blank")
      (h.eq :after (. rows (+ code-screen-row 2))
            "following text starts after bottom padding")
      (h.eq (vim.fn.screenattr code-screen-row 1)
            (vim.fn.screenattr (- code-screen-row 1) 1)
            "top padding has the code background")
      (h.eq (vim.fn.screenattr code-screen-row 1)
            (vim.fn.screenattr (+ code-screen-row 1) 1)
            "bottom padding has the code background"))
    (vim.api.nvim_win_set_cursor 0 [3 0])
    (vim.cmd.redraw)
    (vim.api.nvim_win_set_cursor 0 [1 0])
    (let [rows (visible_rows 12)
          code-screen-row (. (vim.fn.screenpos 0 3 1) :row)]
      (h.eq "" (. rows (- code-screen-row 1))
            "top padding survives cursor movement")
      (h.eq "" (. rows (+ code-screen-row 1))
            "bottom padding survives cursor movement"))))

(fn test-buffer-edges []
  (mada.setup {:anti_conceal false :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (set vim.o.lines 30)
  (let [buf (scratch ["```" :first "```"])]
    (mada.render buf)
    (let [rows (visible_rows 8)
          code-screen-row (. (vim.fn.screenpos 0 2 1) :row)]
      (check (> code-screen-row 1) "top padding appears at buffer start")
      (h.eq "" (. rows (- code-screen-row 1))
            "top padding follows hidden fence")
      (h.eq " first" (. rows code-screen-row) "one-space code inset")
      (h.eq "" (. rows (+ code-screen-row 1)) "bottom padding at buffer end")))
  (let [buf (scratch ["```" :last])]
    (mada.render buf)
    (let [rows (visible_rows 8)
          code-screen-row (. (vim.fn.screenpos 0 2 1) :row)]
      (h.eq "" (. rows (- code-screen-row 1)) "unterminated top padding")
      (h.eq " last" (. rows code-screen-row) "unterminated one-space inset")
      (h.eq "" (. rows (+ code-screen-row 1))
            "unterminated bottom padding at EOF"))))

(fn test-empty-fenced []
  (mada.setup {:anti_conceal false :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (set vim.o.lines 30)
  (let [buf (scratch [:before "```" "```" :after])]
    (mada.render buf)
    (let [rows (visible_rows 7)]
      (h.eq :before (. rows 1) "preceding text")
      (h.eq "" (. rows 2) "opening fence is shaded top padding")
      (h.eq "" (. rows 3) "closing fence is shaded bottom padding")
      (h.eq :after (. rows 4) "following text")
      (h.eq (vim.fn.screenattr 2 1) (vim.fn.screenattr 3 1)
            "empty block padding rows have the same background"))))

(fn check-scrolled-block [mode]
  (mada.setup {:anti_conceal false
               :treesitter {:highlight mode}
               :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (set vim.o.lines 30)
  (let [lines []]
    (for [_ 1 25] (table.insert lines :before))
    (each [_ line (ipairs ["```lua" "scrolled code" "```" :after])]
      (table.insert lines line))
    (for [_ 1 25] (table.insert lines :tail))
    (let [buf (scratch lines)]
      (mada.render buf)
      (vim.api.nvim_win_set_cursor 0 [27 0])
      (vim.cmd "normal! zz")
      (vim.cmd.redraw)
      (let [screen-row (. (vim.fn.screenpos 0 27 1) :row)]
        (check (> screen-row 1) "scrolled code is visible")
        (h.eq "" (trim (h.screen_row (- screen-row 1) 40))
              "scrolled top padding is visible")
        (h.eq " scrolled code" (trim (h.screen_row screen-row 40))
              "scrolled content has one-space inset")
        (h.eq "" (trim (h.screen_row (+ screen-row 1) 40))
              "scrolled bottom padding precedes hidden closing fence")
        (h.eq :after (trim (h.screen_row (+ screen-row 2) 40))
              "following content stays after bottom padding"))
      (vim.api.nvim_win_set_cursor 0 [53 0])
      (vim.cmd "normal! zz")
      (vim.api.nvim_win_set_cursor 0 [27 0])
      (vim.cmd "normal! zz")
      (vim.cmd.redraw)
      (let [screen-row (. (vim.fn.screenpos 0 27 1) :row)]
        (h.eq "" (trim (h.screen_row (- screen-row 1) 40))
              "top padding survives scroll round trip")
        (h.eq "" (trim (h.screen_row (+ screen-row 1) 40))
              "bottom padding survives scroll round trip")))))

(fn test-scroll-round-trip []
  (check-scrolled-block false)
  (check-scrolled-block true))

(fn check-ctrl-y [mode shape]
  "Scroll one screen line at a time across both fence rows. Neovim can stop
scrolling at a concealed fence next to virt_lines even though centered views
look correct."
  (mada.setup {:anti_conceal false
               :treesitter {:highlight mode}
               :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (set vim.o.lines 20)
  (let [lines []]
    (for [i 1 30] (table.insert lines (.. :before i)))
    (each [_ line (ipairs (if (= shape :unterminated)
                              ["```lua" :code]
                              ["```lua" :code "```"]))]
      (table.insert lines line))
    (when (= shape :adjacent)
      (each [_ line (ipairs ["```sh" :second "```"])]
        (table.insert lines line)))
    (when (and (not= shape :eof) (not= shape :unterminated))
      (for [i 1 30] (table.insert lines (.. :after i))))
    (let [buf (scratch lines)
          key (vim.api.nvim_replace_termcodes :<C-y> true false true)]
      (mada.render buf)
      (vim.api.nvim_win_set_cursor 0 [(length lines) 0])
      (vim.cmd "normal! zt")
      (var reached false)
      (var stalled false)
      (for [_ 1 100]
        (when (and (not reached) (not stalled))
          (let [before (vim.fn.winsaveview)]
            (vim.api.nvim_feedkeys key :xt false)
            (let [after (vim.fn.winsaveview)]
              (if (<= after.topline 1)
                  (set reached true)
                  (when (and (= after.topline before.topline)
                             (= after.topfill before.topfill))
                    (set stalled true)))))))
      (check reached (.. "Ctrl-Y stalled before top: " shape ", highlighting="
                         (tostring mode))))))

(fn test-ctrl-y []
  (each [_ mode (ipairs [false true])]
    (each [_ shape (ipairs [:ordinary :adjacent :eof :unterminated])]
      (check-ctrl-y mode shape))))

[["one-line fenced code has top and bottom screen padding"
  test-one-line-fenced]
 ["fenced code padding survives buffer boundaries" test-buffer-edges]
 ["empty fenced block uses its fence rows for padding" test-empty-fenced]
 ["fenced code padding survives scrolling with treesitter on and off"
  test-scroll-round-trip]
 ["Ctrl-Y crosses ordinary, adjacent, closed and unterminated EOF fences"
  test-ctrl-y]]
