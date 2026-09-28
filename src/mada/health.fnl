;; mada.health - :checkhealth mada (FR-H, architecture §11).

(local log (require :mada.log))
(local config (require :mada.config))
(local state (require :mada.state))

(local M {})

(fn normalize_cmd [cmd]
  (if (= (type cmd) :string) [cmd] cmd))

(fn check_parser [lang]
  (let [(ok _) (pcall vim.treesitter.language.inspect lang)]
    (if ok
        (vim.health.ok (: "%s parser loadable" :format lang))
        (vim.health.error (: "%s parser not found" :format lang)))))

(fn check_termaid [cfg]
  "Executable found (exepath of cmd[1]) plus a smoke render of `graph LR;
A-->B`, the only blocking vim.system call in the plugin (NFR-P4). Python
present, info-only, when cmd[1] is literally \"termaid\"."
  (let [cmd (normalize_cmd cfg.mermaid.cmd)
        bin (. cmd 1)
        path (vim.fn.exepath bin)]
    (if (= path "")
        (vim.health.error (: "termaid executable not found: %s" :format
                             (tostring bin)))
        (do
          (vim.health.ok (: "termaid executable found: %s" :format path))
          (let [argv (vim.list_extend (vim.deepcopy cmd) [:--width :80])
                (ok proc) (pcall vim.system argv
                                 {:stdin "graph LR; A-->B" :text true})
                (ok2 obj) (if ok (pcall proc.wait proc 3000) (values false nil))]
            (if (and ok ok2 obj (= obj.code 0))
                (vim.health.ok "termaid smoke render succeeded (graph LR; A-->B)")
                (vim.health.error (: "termaid smoke render failed: %s" :format
                                     (if (and ok2 obj)
                                         (or (and obj.stderr
                                                  (not= obj.stderr "")
                                                  obj.stderr)
                                             (: "exit %s" :format
                                                (tostring obj.code)))
                                         "backend did not run")))))
          (when (= bin :termaid)
            (if (not= (vim.fn.exepath :python3) "")
                (vim.health.info "Python 3 found")
                (vim.health.info "Python 3 not found")))))))

(fn check_conflicts []
  (let [names (icollect [_ n (ipairs [:render-markdown :markview])]
                (if (. package.loaded n) n nil))]
    (if (> (length names) 0)
        (vim.health.warn (: "conflicting Markdown renderer(s) loaded: %s"
                            :format (table.concat names ", ")))
        (vim.health.ok "no conflicting Markdown renderer loaded"))))

(fn check_window_options []
  "Windows mada is rendering whose conceallevel/concealcursor differ from
what mada set (a user autocommand overrode them after the fact)."
  (var any_bad false)
  (each [_ win (ipairs (vim.api.nvim_list_wins))]
    (let [buf (vim.api.nvim_win_get_buf win)
          st (state.get buf)]
      (when (and st (not st.raw))
        (let [want_cc (if st.cfg.anti_conceal "" :nvc)
              (ok_cl cl) (pcall vim.api.nvim_get_option_value :conceallevel
                                {:scope :local : win})
              (ok_cc cc) (pcall vim.api.nvim_get_option_value :concealcursor
                                {:scope :local : win})]
          (when (and ok_cl ok_cc (or (not= cl 2) (not= cc want_cc)))
            (set any_bad true)
            (vim.health.warn (: "window %d: conceallevel/concealcursor overridden (got %s/%s, mada set 2/%s)"
                                :format win (tostring cl) (tostring cc) want_cc)))))))
  (when (not any_bad)
    (vim.health.ok "rendered windows' conceallevel/concealcursor match what mada set")))

(fn check_highlighter []
  "Whether a tree-sitter highlighter is active for the current buffer, and
who started it (mada or the user)."
  (let [buf (vim.api.nvim_get_current_buf)]
    (if (not= (. vim.bo buf :filetype) :markdown)
        (vim.health.info "tree-sitter highlighter: current buffer is not markdown")
        (let [st (state.get buf)
              active (not= (. vim.treesitter.highlighter.active buf) nil)]
          (if (not active)
              (vim.health.info "tree-sitter highlighter: not active for the current buffer")
              (vim.health.info (: "tree-sitter highlighter: active for the current buffer (started by %s)"
                                  :format
                                  (if (and st st.started_ts) :mada :user))))))))

(fn check_timings []
  "The `render` ring mixes non-edit renders (NFR-P1: 8ms/16ms) with
parse-bound edit renders (NFR-P10: 25ms/40ms), so it is graded against
NFR-P10's looser budget to avoid false alarms on ordinary edits."
  (let [timings (log.render_timings)]
    (if (= (length timings) 0)
        (vim.health.info "no renders recorded yet")
        (let [sorted (icollect [_ v (ipairs timings)] v)]
          (table.sort sorted)
          (let [n (length sorted)
                p95i (math.max 1 (math.ceil (* n 0.95)))
                p95 (. sorted p95i)
                mx (. sorted n)]
            (vim.health.info (: "render timings (all renders, mixed): p95 %.2fms max %.2fms (n=%d)"
                                :format p95 mx n))
            (if (or (> p95 25) (> mx 40))
                (vim.health.warn "render timings are over the NFR-P10 budget (p95 25ms / max 40ms)")
                (vim.health.ok "render timings within the NFR-P10 budget")))))))

(fn check_config_summary [cfg]
  (vim.health.info (: "config: enabled=%s filetypes=%s treesitter.highlight=%s ascii=%s mermaid.cmd=%s mermaid.placement=%s"
                      :format (tostring cfg.enabled)
                      (table.concat cfg.filetypes ",")
                      (tostring cfg.treesitter.highlight) (tostring cfg.ascii)
                      (table.concat (normalize_cmd cfg.mermaid.cmd) " ")
                      cfg.mermaid.placement)))

(fn M.check []
  (vim.health.start :mada)
  (if (vim.fn.has :nvim-0.11)
      (vim.health.ok (: "Neovim %s" :format (tostring (vim.version))))
      (vim.health.error "Neovim >= 0.11 required"))
  (check_parser :markdown)
  (check_parser :markdown_inline)
  (let [cfg (config.get)]
    (check_termaid cfg)
    (check_conflicts)
    (check_window_options)
    (check_highlighter)
    (check_timings)
    (check_config_summary cfg)))

M
