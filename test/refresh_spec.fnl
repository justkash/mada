;; test.refresh_spec - FR-T3 regression for events.fnl's M.refresh: a buffer
;; edited while hidden (no window showing it - a formatter, or another
;; plugin's API call via nvim_buf_set_lines) must be re-parsed when it
;; becomes visible again, not silently marked clean by a blind changedtick
;; resync. Direct API calls (nvim_win_set_buf, nvim_buf_set_lines) fire
;; BufEnter/BufWinEnter/WinEnter synchronously even from a `-l` script (only
;; CursorMoved/WinScrolled/TextChanged/ModeChanged are the deferred ones,
;; OQ-5), so this runs in-process via test/helpers rather than an RPC child.

(local h (require :helpers))
(local config (require :mada.config))
(local events (require :mada.events))

(fn find-h1 [ms row]
  (var found nil)
  (each [_ m (ipairs ms)]
    (when (and (= m.row row) (= m.opts.hl_group :MadaH1)) (set found m)))
  found)

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn test-hidden-edit-reparsed-on-return []
  (config.setup {})
  (let [win (vim.api.nvim_get_current_win)
        buf (vim.api.nvim_create_buf true false)
        other (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["# Heading" "" :para])
    (vim.api.nvim_win_set_buf win buf)
    (set vim.bo.filetype :markdown)
    (check (not= nil (find-h1 (h.marks buf) 0))
           "precondition: row 0 should carry MadaH1 before hiding the buffer")
    ;; Hide buf: the only window now shows a different buffer, so no window
    ;; renders TextChanged for edits made to buf while it is hidden.
    (vim.api.nvim_win_set_buf win other)
    ;; Edit the hidden buffer directly, as a formatter or another plugin
    ;; would via the API, bumping changedtick with no TextChanged on buf.
    (vim.api.nvim_buf_set_lines buf 0 1 false ["# Changed Heading"])
    (let [line (. (vim.api.nvim_buf_get_lines buf 0 1 false) 1)]
      ;; Switch back: BufEnter/BufWinEnter/WinEnter -> sync + refresh.
      (vim.api.nvim_win_set_buf win buf)
      (let [ms (h.marks buf)
            h1 (find-h1 ms 0)]
        (check (not= h1 nil) "the edited heading row should still carry MadaH1")
        (h.eq (length line) h1.opts.end_col
              "the H1 highlight should cover the edited heading text (fresh parse), not the stale pre-edit bounds")))))

(fn has-conceal? [ms row]
  (var found false)
  (each [_ m (ipairs ms)]
    (when (and (= m.row row) (not= m.opts.conceal nil)) (set found true)))
  found)

(fn test-jump-scroll-renders-inline-marks-in-newly-parsed-region []
  "Regression: LanguageTree:trees() of the markdown_inline child becomes a
sparse table once more than one ranged parse has run (Neovim 0.12); building
the tree index with ipairs (which stops at the first gap) missed the trees
injected by a later ranged parse, and get_tree_index's changedtick-only
cache then kept serving that stale index across further renders (same
changedtick, no edit). Reproduces by rendering near the top of
reference.md (attach's own render), then jumping far down and rendering that
viewport too, without any edit in between."
  (config.setup {})
  (let [win (vim.api.nvim_get_current_win)
        buf (h.open :reference.md)]
    ;; attach already rendered the viewport around row 0; now jump to row
    ;; 1003 (line 1004) and scroll it to the top of the window, then render
    ;; that viewport, mirroring `:1004` + `zt` + a real render.
    (vim.cmd :1004)
    (vim.cmd "normal! zt")
    (events.render_view buf win)
    (check (has-conceal? (h.marks buf) 1003)
           "row 1003 (*emphasis*, **strong**, ~~strikethrough~~) should carry conceal marks after jumping/scrolling to it")
    (let [before (h.render_stats)]
      (events.render_view buf win)
      (let [after (h.render_stats)]
        (h.eq before.parses after.parses
              "re-rendering an already-parsed viewport with no edit in between should not bump render.stats().parses")))))

[["hidden-buffer edit (nvim_buf_set_lines) is reparsed on return, not stale"
  test-hidden-edit-reparsed-on-return]
 ["jump+scroll into an unparsed region then render_view: inline marks appear, and a repeat render_view with no edit does not reparse"
  test-jump-scroll-renders-inline-marks-in-newly-parsed-region]]
