;; mada.events - autocommands, mode sync, window options, anti-conceal.

(local state (require :mada.state))
(local render (require :mada.render))
(local mermaid (require :mada.mermaid))
(local tables (require :mada.tables))
(local inline (require :mada.inline))
(local hl (require :mada.hl))
(local highlighter (require :mada.highlighter))
(local log (require :mada.log))

(local M {})

(fn windows_for_buf [buf]
  (icollect [_ w (ipairs (vim.api.nvim_list_wins))]
    (if (= (vim.api.nvim_win_get_buf w) buf) w)))

(fn keep? [m]
  (let [c1 (m:sub 1 1)]
    (or (= c1 :c) (= c1 :r) (= c1 "!") (= (m:sub 1 2) :no))))

(fn want_raw? [cfg m]
  (or (vim.tbl_contains cfg.raw_modes (m:sub 1 1)) (= (m:sub 1 2) :ni)))

(fn conflict? []
  (or (. package.loaded :render-markdown) (. package.loaded :markview)))

(fn set_rendered_opts [win cfg]
  "Save the window's pre-mada conceallevel/concealcursor once, then set what
mada renders with. A `:split` of a rendered window copies mada's own local
values (conceallevel=2, concealcursor set), so if the window's local values
already equal what mada sets while its *global* values differ, the global
values are the pre-mada ones inherited from the source window (mada only
ever sets local scope) and are saved instead (UR-6)."
  (let [saved (. vim.w win :mada)]
    (when (not saved)
      (let [want_cc (if cfg.anti_conceal "" :nvc)
            local_cl (vim.api.nvim_get_option_value :conceallevel
                                                    {:scope :local : win})
            local_cc (vim.api.nvim_get_option_value :concealcursor
                                                    {:scope :local : win})
            global_cl (vim.api.nvim_get_option_value :conceallevel
                                                     {:scope :global : win})
            global_cc (vim.api.nvim_get_option_value :concealcursor
                                                     {:scope :global : win})
            already_mada? (and (= local_cl 2) (= local_cc want_cc))
            globals_differ? (or (not= global_cl local_cl)
                                (not= global_cc local_cc))]
        (tset (. vim.w win) :mada
              (if (and already_mada? globals_differ?)
                  {:conceallevel global_cl :concealcursor global_cc}
                  {:conceallevel local_cl :concealcursor local_cc}))))
    (vim.api.nvim_set_option_value :conceallevel 2 {:scope :local : win})
    (vim.api.nvim_set_option_value :concealcursor
                                   (if cfg.anti_conceal "" :nvc)
                                   {:scope :local : win})))

(fn restore_opts [win]
  (let [saved (. vim.w win :mada)]
    (when saved
      (pcall vim.api.nvim_set_option_value :conceallevel saved.conceallevel
             {:scope :local : win})
      (pcall vim.api.nvim_set_option_value :concealcursor saved.concealcursor
             {:scope :local : win})
      (tset (. vim.w win) :mada nil))))

(fn viewport_range [buf win cfg]
  (let [total (vim.api.nvim_buf_line_count buf)
        w0 (- (vim.fn.line :w0 win) 1)
        w$ (- (vim.fn.line :w$ win) 1)
        margin cfg.viewport_margin]
    (values (math.max 0 (- w0 margin)) (math.min (- total 1) (+ w$ margin)))))

(fn M.render_view [buf win]
  "Render win's viewport range and mark it clean."
  (let [st (state.get buf)]
    (when (and st (not st.raw))
      (let [(a b) (viewport_range buf win st.cfg)]
        (render.render buf win a b true)
        (tset st.clean win [a b])))))

(fn M.refresh [buf win]
  "Render only the rows of win's viewport range not already clean (FR-T3).
Neovim can bump changedtick between the parsing render at attach and the
first BufEnter/BufWinEnter/WinEnter even with no text edit at all (observed
independently of mada, e.g. after FileType with no content change). A real
edit can also reach here with no prior TextChanged, when it happened while
the buffer was hidden (no window showing it: a formatter, or another
plugin's API call). Either way, when changedtick has moved since the last
parsing render, that render must itself be a parse: render_view (a parsing
render of the whole viewport range), never a blind resync of st.tick, so a
change made while hidden is never skipped (FR-T3)."
  (let [st (state.get buf)]
    (when (and st (not st.raw))
      (if (not= (vim.api.nvim_buf_get_changedtick buf) st.tick)
          (M.render_view buf win)
          (let [(a b) (viewport_range buf win st.cfg)
                prev (. st.clean win)]
            (if (not prev)
                (M.render_view buf win)
                (let [pa (. prev 1)
                      pb (. prev 2)]
                  (if (or (> a (+ pb 1)) (< b (- pa 1)))
                      (M.render_view buf win)
                      (do
                        (when (< a pa)
                          (render.render buf win a (- pa 1) true))
                        (when (> b pb)
                          (render.render buf win (+ pb 1) b true))
                        (tset st.clean win [(math.min a pa) (math.max b pb)]))))))))))

(fn M.enter_raw [buf]
  "Clear the namespace, restore window options, note nothing is clean."
  (let [st (state.get buf)]
    (when st
      (set st.raw true)
      (vim.api.nvim_buf_clear_namespace buf (state.ns) 0 -1)
      (set st.clean {})
      (each [_ w (ipairs (windows_for_buf buf))]
        (restore_opts w)))))

(fn M.enter_rendered [buf]
  "Refresh st.cursor from the current cursor, set window options and render
the viewport range (FR-T6) in every window showing buf."
  (let [st (state.get buf)]
    (when st
      (set st.raw false)
      (let [cw (vim.api.nvim_get_current_win)]
        (when (= (vim.api.nvim_win_get_buf cw) buf)
          (set st.cursor (- (. (vim.api.nvim_win_get_cursor cw) 1) 1))))
      (each [_ w (ipairs (windows_for_buf buf))]
        (set_rendered_opts w st.cfg)
        (M.render_view buf w)))))

(fn M.sync [buf]
  "Enter raw or rendered mode if the current mode's display state differs
from st.raw (FR-M3)."
  (let [st (state.get buf)]
    (when st
      (let [m (vim.fn.mode 1)]
        (when (not (keep? m))
          (let [wr (want_raw? st.cfg m)]
            (when (not= wr st.raw)
              (if wr (M.enter_raw buf) (M.enter_rendered buf)))))))))

(fn mode_transition_label [buf]
  "The direction M.sync is about to transition `buf`, or nil when this
ModeChanged will not change display state (kept mode, or already in the
target state). Computed with the same keep?/want_raw? logic M.sync uses, so
the two directions can be timed under distinct labels (NFR-P1 entering
rendered mode is a full render; NFR-P2 entering raw mode is not) rather than
mixed together under one `ModeChanged` label."
  (let [st (state.get buf)]
    (when st
      (let [m (vim.fn.mode 1)]
        (when (not (keep? m))
          (let [wr (want_raw? st.cfg m)]
            (when (not= wr st.raw)
              (if wr "ModeChanged:raw" "ModeChanged:rendered"))))))))

(fn render_cursor_target [buf win row blk other_blk]
  "Anti-conceal target for `row`: when the cursor enters or leaves a Mermaid
block, re-render its rows plus its anchor row (the diagram's virt_lines
attach there, invariant 2 with anchor rows); otherwise just `row`."
  (when (>= row 0)
    (if (and blk (not= blk other_blk))
        (let [(lo hi) (mermaid.render_range buf blk)]
          (render.render buf win lo hi false))
        (render.render buf win row row false))))

(fn M.on_cursor_moved [buf]
  "Anti-conceal: re-render the previous and new cursor rows (or Mermaid
block) without parsing (FR-AC2). A pipe table row now carries only its own
overlay/virt_lines marks (FR-R13's draw-over-source design), so the cursor
moving on or off one needs no extra row re-rendered, same as any other row."
  (let [st (state.get buf)]
    (when (and st (not st.raw))
      (let [win (vim.api.nvim_get_current_win)
            row (- (. (vim.api.nvim_win_get_cursor win) 1) 1)
            prev st.cursor]
        (set st.cursor row)
        (when (and (not= row prev)
                   (= (vim.api.nvim_buf_get_changedtick buf) st.tick))
          (let [pb (mermaid.block_at buf prev)
                nb (mermaid.block_at buf row)]
            (render_cursor_target buf win prev pb nb)
            (render_cursor_target buf win row nb pb)))))))

(fn M.on_text_changed [buf]
  "Re-render every window showing buf, unless already rendered for this
changedtick (ModeChanged already rendered it on leaving Insert)."
  (let [st (state.get buf)]
    (when (and st (not st.raw))
      (when (not= (vim.api.nvim_buf_get_changedtick buf) st.tick)
        (each [_ w (ipairs (windows_for_buf buf))]
          (M.render_view buf w))))))

(fn M.on_buf_leave [buf]
  (let [st (state.get buf)]
    (when (and st st.raw)
      (M.enter_rendered buf))))

(fn M.on_buf_read_post [buf]
  (let [st (state.get buf)]
    (when st
      (vim.api.nvim_buf_clear_namespace buf (state.ns) 0 -1)
      (vim.api.nvim_buf_clear_namespace buf (state.anchor_ns) 0 -1)
      (set st.blocks {})
      (set st.clean {})
      (M.enter_rendered buf))))

(fn M.detach [buf]
  "Clear marks, restore options, restore the highlighter to what it was
before mada attached (stop one mada started, or restart one mada stopped -
FR-M10, FR-M11), detach autocommands and release state (FR-M7, FR-M8)."
  (let [st (state.get buf)]
    (when st
      (highlighter.restore buf)
      (vim.api.nvim_buf_clear_namespace buf (state.ns) 0 -1)
      (vim.api.nvim_buf_clear_namespace buf (state.anchor_ns) 0 -1)
      (each [_ w (ipairs (windows_for_buf buf))]
        (restore_opts w))
      (when st.started_ts
        (pcall vim.treesitter.stop buf))
      (when st.stopped_ts
        (pcall vim.treesitter.start buf :markdown))
      (mermaid.detach buf)
      (inline.detach buf)
      (tables.detach buf)
      (pcall vim.api.nvim_del_augroup_by_name (.. :mada. buf))
      (state.clear buf))))

(fn force_syntax_off [buf]
  "Force buf's legacy regex 'syntax' back off after stopping a tree-sitter
highlighter. Neovim 0.12's runtime/syntax/syntax.vim installs a `syntaxset`
FileType autocmd guarded by `b:ts_highlight`
(`if !exists('b:ts_highlight') | 0verbose exe \"set syntax=\" .
expand(\"<amatch>\") | endif`), and TSHighlighter:destroy() (what
`vim.treesitter.stop` runs) clears that variable *before* re-firing FileType
for that augroup. So with `:syntax on` active (`vim.g.syntax_on == 1`, the
Neovim default), stopping the highlighter re-enables legacy regex
syntax/markdown.vim highlighting - with its own conceals under
`g:markdown_syntax_conceal` - at exactly the moment mada meant to leave
nothing running. Force it back off right after stopping to get the intended
net result: no highlighter, no regex syntax, while mada renders the buffer."
  (pcall vim.api.nvim_set_option_value :syntax "" {: buf}))

(fn maybe_start_highlighter [buf st cfg]
  "FR-M10, FR-M11 (architecture §13): apply `cfg.treesitter.highlight` to
buf's *current* highlighter state. Idempotent (re-reads
vim.treesitter.highlighter.active every call), so it is safe to call again
later without double-starting or double-stopping: the vim.schedule recheck
in M.attach, and a setup() config change via M.reevaluate_highlighter, both
just call this again.
  `false`, or `\"auto\"` over `treesitter.auto_max_lines` lines - stop any
    active highlighter, whoever started it (including Neovim's runtime
    ftplugin/markdown.lua's own `vim.treesitter.start()` under `filetype
    plugin on`), forcing `syntax` off too (force_syntax_off), and record
    that mada stopped one (st.stopped_ts) so M.detach can restart it and
    restore the original state.
  `true`, or `\"auto\"` at or under the line limit - ensure one is running:
    start it if none is active (st.started_ts = true, so M.detach knows to
    stop it on detach); leave an already-active one alone, whoever started
    it (st.started_ts = false)."
  (let [mode cfg.treesitter.highlight
        was_active (not= (. vim.treesitter.highlighter.active buf) nil)
        too_big? (and (= mode :auto)
                      (> (vim.api.nvim_buf_line_count buf)
                         cfg.treesitter.auto_max_lines))]
    (if (or (= mode false) too_big?)
        (do
          (highlighter.restore buf)
          (when was_active
            (pcall vim.treesitter.stop buf)
            (force_syntax_off buf))
          (set st.started_ts false)
          (set st.stopped_ts was_active))
        (do
          (when (not was_active)
            (pcall vim.treesitter.start buf :markdown))
          (highlighter.install buf)
          (set st.started_ts (not was_active))
          (set st.stopped_ts false)))))

(fn M.reevaluate_highlighter [buf st cfg]
  "FR-C5: re-apply FR-M10/FR-M11's rules for `cfg` to an already-attached
buf on a setup() config change. Delegates to maybe_start_highlighter (it
re-reads the highlighter's *current* active state), so this stops one no
matter who started it when the new config wants none running, and restarts
one mada previously stopped when the new config wants one again."
  (maybe_start_highlighter buf st cfg))

(fn on_filetype_check [buf]
  "Buffer-scoped: detach if the filetype changed away from the configured
set."
  (let [st (state.get buf)]
    (when (and st
               (not (vim.tbl_contains st.cfg.filetypes (. vim.bo buf :filetype))))
      (M.detach buf))))

(fn register_buffer_autocmds [buf]
  (let [grp (vim.api.nvim_create_augroup (.. :mada. buf) {:clear true})]
    (vim.api.nvim_create_autocmd [:BufEnter :BufWinEnter :WinEnter]
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :BufEnter buf
                                                         (fn []
                                                           (let [st (state.get buf)]
                                                             (when st
                                                               (let [win (vim.api.nvim_get_current_win)]
                                                                 (when (not st.raw)
                                                                   (set_rendered_opts win
                                                                                      st.cfg))
                                                                 (M.sync buf)
                                                                 (M.refresh buf
                                                                            win)))))))})
    (vim.api.nvim_create_autocmd :TextChanged
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :TextChanged buf
                                                         M.on_text_changed buf))})
    (vim.api.nvim_create_autocmd :CursorMoved
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :CursorMoved buf
                                                         M.on_cursor_moved buf))})
    (vim.api.nvim_create_autocmd :BufLeave
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :BufLeave buf
                                                         M.on_buf_leave buf))})
    (vim.api.nvim_create_autocmd :BufReadPost
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :BufReadPost buf
                                                         M.on_buf_read_post buf))})
    (vim.api.nvim_create_autocmd :FileType
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :FileType buf
                                                         on_filetype_check buf))})
    (vim.api.nvim_create_autocmd [:BufUnload :BufWipeout]
                                 {:group grp
                                  :buffer buf
                                  :callback (fn []
                                              (log.guard :BufUnload buf
                                                         M.detach buf))})))

(fn schedule_highlighter_recheck [buf]
  "The runtime ftplugin/markdown.lua's own `vim.treesitter.start()` (under
`filetype plugin on`) can run after mada's FileType attach in the same
FileType event, leaving a highlighter running that maybe_start_highlighter
already judged (FR-M10). Re-check once more shortly after attach, only if
buf is still attached and in rendered mode (a `:Mada disable` or a mode
switch to raw in between means there is nothing left to re-check)."
  (vim.schedule (fn []
                  (log.guard :HighlighterRecheck buf
                             (fn []
                               (let [st (state.get buf)]
                                 (when (and st (not st.raw))
                                   (maybe_start_highlighter buf st st.cfg))))))))

(fn M.attach [buf ?notify]
  "Attach buf if its filetype is configured, it is not disabled, it is not
over max_file_lines and no conflicting renderer is loaded (FR-M1, FR-M2,
FR-M9). Idempotent."
  (when (not (state.get buf))
    (let [config (require :mada.config)
          cfg (config.get)]
      (when cfg.enabled
        (when (not (. vim.b buf :mada_disabled))
          (let [nlines (vim.api.nvim_buf_line_count buf)]
            (if (> nlines cfg.max_file_lines)
                (when ?notify
                  (vim.notify "mada: buffer exceeds max_file_lines, not attached"
                              vim.log.levels.WARN))
                (if (conflict?)
                    (log.notify_once :conflict
                                     "mada: another Markdown renderer is active; mada stays disabled for this buffer"
                                     vim.log.levels.WARN)
                    (let [st (state.ensure buf (vim.deepcopy cfg))]
                      (maybe_start_highlighter buf st cfg)
                      (register_buffer_autocmds buf)
                      (if (want_raw? cfg (vim.fn.mode 1))
                          (set st.raw true)
                          (M.enter_rendered buf))
                      (schedule_highlighter_recheck buf))))))))))

(fn M.setup_global [cfg]
  "(Re)register the global autocommands (FileType, ModeChanged, WinScrolled,
WinResized, ColorScheme). Called on every setup()."
  (let [grp (vim.api.nvim_create_augroup :mada {:clear true})]
    (vim.api.nvim_create_autocmd :FileType
                                 {:group grp
                                  :pattern cfg.filetypes
                                  :callback (fn [ev]
                                              (log.guard :FileType ev.buf
                                                         M.attach ev.buf))})
    (vim.api.nvim_create_autocmd :ModeChanged
                                 {:group grp
                                  :callback (fn []
                                              (let [buf (vim.api.nvim_get_current_buf)
                                                    label (or (mode_transition_label buf)
                                                              :ModeChanged)]
                                                (log.guard label buf M.sync buf)))})
    (vim.api.nvim_create_autocmd :WinScrolled
                                 {:group grp
                                  :callback (fn []
                                              (each [win_s _ (pairs vim.v.event)]
                                                (let [win (tonumber win_s)]
                                                  (when win
                                                    (let [buf (vim.api.nvim_win_get_buf win)]
                                                      (log.guard :WinScrolled
                                                                 buf M.refresh
                                                                 buf win))))))})
    (vim.api.nvim_create_autocmd :WinResized
                                 {:group grp
                                  :callback (fn []
                                              (each [_ win (ipairs vim.v.event.windows)]
                                                (let [buf (vim.api.nvim_win_get_buf win)]
                                                  (log.guard :WinResized buf
                                                             M.render_view buf
                                                             win))))})
    (vim.api.nvim_create_autocmd :ColorScheme
                                 {:group grp
                                  :callback (fn []
                                              (log.guard :ColorScheme nil
                                                         hl.define))})
    (vim.api.nvim_create_autocmd :OptionSet
                                 {:group grp
                                  :pattern [:wrap
                                            :linebreak
                                            :showbreak
                                            :breakindent
                                            :number
                                            :relativenumber
                                            :numberwidth
                                            :signcolumn
                                            :foldcolumn
                                            :statuscolumn]
                                  :callback (fn []
                                              (let [win (vim.api.nvim_get_current_win)
                                                    buf (vim.api.nvim_win_get_buf win)]
                                                (log.guard :OptionSet buf
                                                           M.render_view buf win)))})))

M
