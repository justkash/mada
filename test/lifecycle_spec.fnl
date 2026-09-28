;; test.lifecycle_spec - AT-1, AT-14, AT-17, AT-22, AT-26; FR-M9, FR-M10.

(local h (require :helpers))
(local mada (require :mada))
(local config (require :mada.config))
(local state (require :mada.state))

(fn scratch_md [lines]
  "A fresh scratch buffer with `lines`, shown in the current window, with
filetype markdown set last (fires the real FileType autocommand)."
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(local heading_lines ["# Heading" "" "para one" "" "## Sub" "" "more text"])

(fn test_AT1_marks_present_tick_unchanged []
  (config.setup {})
  (let [buf (scratch_md heading_lines)
        tick0 (vim.api.nvim_buf_get_changedtick buf)]
    (h.eq true (> (length (h.marks buf)) 0))
    (mada.render buf)
    (h.eq tick0 (vim.api.nvim_buf_get_changedtick buf))))

(fn test_AT22_edit_renders_before_any_wait []
  (vim.cmd.edit :test/fixtures/headings.md)
  (set vim.bo.filetype :markdown)
  (let [buf (vim.api.nvim_get_current_buf)]
    (h.eq true (> (length (h.marks buf)) 0))))

(fn test_AT14_disable_restores_both_windows []
  ;; Both windows must see the buffer's *true* pre-mada conceallevel, so
  ;; split before attaching: a split created after mada already rendered
  ;; the buffer inherits its current (already 2) conceallevel by copy,
  ;; which is not a meaningful "original" to restore.
  (config.setup {})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false heading_lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (let [win1 (vim.api.nvim_get_current_win)]
      ;; a prior test may have left this (reused) window at conceallevel=2
      ;; without a matching vim.w[win].mada save; start from a clean slate.
      (vim.api.nvim_set_option_value :conceallevel 0 {:scope :local :win win1})
      (vim.cmd.split)
      (let [win2 (vim.api.nvim_get_current_win)]
        (set vim.bo.filetype :markdown)
        (h.eq 2
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win1})
              "win1 before disable")
        (h.eq 2
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win2})
              "win2 before disable")
        (mada.disable buf)
        (h.eq 0
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win1})
              "win1 after disable")
        (h.eq 0
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win2})
              "win2 after disable")
        (vim.api.nvim_win_close win2 true)))))

(fn test_AT17_max_file_lines []
  (config.setup {:max_file_lines 3})
  (let [buf (scratch_md heading_lines)]
    (h.eq false (mada.is_enabled buf))
    (var notified nil)
    (let [orig vim.notify]
      (set vim.notify (fn [msg _level] (set notified msg)))
      (mada.enable buf)
      (set vim.notify orig))
    (h.eq false (mada.is_enabled buf))
    (h.eq true (not= notified nil)))
  (config.setup {}))

(fn test_AT26_only_conceal_options_change []
  (config.setup {})
  (let [buf (scratch_md heading_lines)
        win (vim.api.nvim_get_current_win)
        keymaps_before (vim.api.nvim_get_keymap :n)
        wrap_before (vim.api.nvim_get_option_value :wrap {:scope :local : win})]
    (h.feed :i)
    (h.feed :<Esc>)
    (h.eq keymaps_before (vim.api.nvim_get_keymap :n))
    (h.eq wrap_before
          (vim.api.nvim_get_option_value :wrap {:scope :local : win}))
    (mada.disable buf)
    (h.eq keymaps_before (vim.api.nvim_get_keymap :n))
    (h.eq 0 (vim.api.nvim_get_option_value :conceallevel {:scope :local : win}))))

(fn test_FRM9_conflict_stays_disabled []
  (tset package.loaded :render-markdown {})
  (var notified nil)
  (let [orig vim.notify]
    (set vim.notify (fn [msg level] (set notified [msg level])))
    (let [buf (scratch_md heading_lines)]
      (h.eq false (mada.is_enabled buf))
      (h.eq true (not= notified nil))
      (h.eq vim.log.levels.WARN (. notified 2)))
    (set vim.notify orig))
  (tset package.loaded :render-markdown nil))

(fn test_FRM10_auto_starts_when_inactive []
  (config.setup {:treesitter {:highlight :auto}})
  (let [buf (scratch_md heading_lines)]
    (h.eq true (not= nil (. vim.treesitter.highlighter.active buf)))
    (h.eq true (. (state.get buf) :started_ts))
    (mada.disable buf)
    (h.eq nil (. vim.treesitter.highlighter.active buf))))

(fn test_FRM10_auto_leaves_user_highlighter []
  (config.setup {:treesitter {:highlight :auto}})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false heading_lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (vim.treesitter.start buf :markdown)
    (set vim.bo.filetype :markdown)
    (h.eq false (. (state.get buf) :started_ts))
    (mada.disable buf)
    (h.eq true (not= nil (. vim.treesitter.highlighter.active buf)))
    (vim.treesitter.stop buf)))

(fn test_FRM10_false_never_starts []
  (config.setup {:treesitter {:highlight false}})
  (let [buf (scratch_md heading_lines)]
    (h.eq nil (. vim.treesitter.highlighter.active buf)))
  (config.setup {}))

(fn test_FRM10_false_stops_active_highlighter []
  "false's new semantics (\"stop the highlighter\"): stop a highlighter
already active at attach, whoever started it, and restore it on
`:Mada disable`. test/highlighter_spec.fnl covers the real runtime
ftplugin/markdown.lua case over RPC (and the 'syntax' side effect); this
covers the state bookkeeping (stopped_ts) synchronously."
  (config.setup {:treesitter {:highlight false}})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false heading_lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (vim.treesitter.start buf :markdown)
    (set vim.bo.filetype :markdown)
    (h.eq nil (. vim.treesitter.highlighter.active buf)
          "false: an already-active highlighter must be stopped on attach")
    (h.eq true (. (state.get buf) :stopped_ts)
          "false: mada should record that it stopped a highlighter")
    (mada.disable buf)
    (h.eq true (not= nil (. vim.treesitter.highlighter.active buf))
          ":Mada disable should restart the highlighter mada stopped, restoring the original state")
    (vim.treesitter.stop buf))
  (config.setup {}))

(fn test_FRC5_resetup_reevaluates_highlighter []
  "FR-C5: re-setup() must re-evaluate treesitter.highlight on already
attached buffers, not just replace st.cfg and re-render."
  (mada.setup {:treesitter {:highlight :auto}})
  (let [buf (scratch_md heading_lines)]
    (h.eq true (not= nil (. vim.treesitter.highlighter.active buf))
          "precondition: auto should start the highlighter on attach")
    (h.eq true (. (state.get buf) :started_ts))
    (mada.setup {:treesitter {:highlight false}})
    (h.eq nil (. vim.treesitter.highlighter.active buf)
          "re-setup with highlight=false should stop the highlighter mada started")
    (h.eq false (. (state.get buf) :started_ts))
    (mada.setup {:treesitter {:highlight :auto}})
    (h.eq true (not= nil (. vim.treesitter.highlighter.active buf))
          "re-setup back to auto should start the highlighter again")
    (h.eq true (. (state.get buf) :started_ts))
    (mada.disable buf))
  (mada.setup {}))

(fn test_NFRQ4_command_api_guarded []
  "NFR-Q4: the Lua API (M.enable etc.) must run under log.guard, like every
autocommand and job callback: an error inside must not raise a raw error out
of the API call, and must produce exactly one ERROR notification."
  (config.setup {})
  (let [events (require :mada.events)
        orig events.attach
        notifications []
        orig-notify vim.notify
        buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false heading_lines)
    (set events.attach (fn [...] (error "boom: stubbed events.attach" 0)))
    (set vim.notify (fn [msg level] (table.insert notifications [msg level])))
    (let [(ok _err) (pcall mada.enable buf)]
      (set events.attach orig)
      (set vim.notify orig-notify)
      (h.eq true ok "mada.enable must not raise a raw error (NFR-Q4)")
      (h.eq 1 (length notifications) "expected exactly one ERROR notification")
      (h.eq vim.log.levels.ERROR (. notifications 1 2)))))

(fn test_NFRP5_detach_clears_inline_caches []
  "NFR-P5: def_cache and tree_index_cache (src/mada/inline.fnl) must not
outlive the buffer they are keyed by."
  (config.setup {})
  (let [inline (require :mada.inline)
        buf (h.open :links.md)]
    (let [(def1 tree1) (inline.cached? buf)]
      (h.eq true tree1
            "precondition: tree_index_cache should be populated after render")
      (h.eq true def1
            "precondition: def_cache should be populated after rendering a reference link"))
    (vim.cmd (.. "bwipeout! " buf))
    (let [(def2 tree2) (inline.cached? buf)]
      (h.eq false def2
            "detach: def_cache should have no entry for a wiped-out buffer")
      (h.eq false tree2
            "detach: tree_index_cache should have no entry for a wiped-out buffer"))))

(fn test_NFRP5_detach_clears_tables_cache []
  "NFR-P5: mada.tables' per-buffer layout cache (FR-P3) must not outlive the
buffer it is keyed by."
  (config.setup {})
  (let [tables (require :mada.tables)
        buf (h.open :tables.md)]
    (h.eq true (tables.cached? buf)
          "precondition: the layout cache should be populated after rendering a table")
    (vim.cmd (.. "bwipeout! " buf))
    (h.eq false (tables.cached? buf)
          "detach: the layout cache should have no entry for a wiped-out buffer")))

[["AT-1 marks present, changedtick unchanged"
  test_AT1_marks_present_tick_unchanged]
 ["AT-22 :edit renders before any wait" test_AT22_edit_renders_before_any_wait]
 ["AT-14 disable restores both windows' options"
  test_AT14_disable_restores_both_windows]
 ["AT-17 oversized buffer not attached, enable notifies"
  test_AT17_max_file_lines]
 ["AT-26 only conceal options change, restored on disable"
  test_AT26_only_conceal_options_change]
 ["FR-M9 conflicting renderer stays disabled"
  test_FRM9_conflict_stays_disabled]
 ["FR-M10 auto starts an inactive highlighter"
  test_FRM10_auto_starts_when_inactive]
 ["FR-M10 auto leaves a user-started highlighter"
  test_FRM10_auto_leaves_user_highlighter]
 ["FR-M10 false never starts a highlighter" test_FRM10_false_never_starts]
 ["FR-M10 false stops an already-active highlighter, restores it on disable"
  test_FRM10_false_stops_active_highlighter]
 ["NFR-P5 detach releases inline.fnl's per-buffer caches"
  test_NFRP5_detach_clears_inline_caches]
 ["NFR-P5 detach releases tables.fnl's per-buffer layout cache"
  test_NFRP5_detach_clears_tables_cache]
 ["FR-C5 re-setup() re-evaluates treesitter.highlight on attached buffers"
  test_FRC5_resetup_reevaluates_highlighter]
 ["NFR-Q4 the Lua API runs under log.guard (no raw error, one notification)"
  test_NFRQ4_command_api_guarded]]
