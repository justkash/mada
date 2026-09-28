;; test.priority_spec - AT-29, NFR-I2: every mark mada sets stays below
;; `vim.hl.priorities.diagnostics` (150), so diagnostics and other plugins'
;; default-priority marks draw over its styling.

(local h (require :helpers))
(local mada (require :mada))

(local fake-cmd (.. (vim.fn.getcwd) :/test/bin/fake-termaid))

;; See test.mermaid_spec: force FR-C6's lazy `mada.setup({})` now, before any
;; test's own config.setup/mada.setup call, so it cannot clobber one later.
(mada.setup {})

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn fixture_names []
  "Sorted basenames of test/fixtures/*.md, excluding reference.md (mermaid
fixtures included: with no backend configured they render as plain code
blocks, whose own conceal_lines/line_hl priorities are checked here too; the
mermaid-specific overlay/virt_lines priority (140) is checked directly below
with a real diagram)."
  (let [files (vim.fn.readdir :test/fixtures)
        names []]
    (each [_ f (ipairs files)]
      (when (and (f:match "%.md$") (not= f :reference.md))
        (table.insert names (pick-values 1 (f:gsub "%.md$" "")))))
    (table.sort names)
    names))

(fn open_fixture [name]
  (mada.setup {:anti_conceal false})
  (set vim.o.columns 80)
  (let [path (.. :test/fixtures/ name :.md)
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (h.open (.. name :.md)))

(fn max_priority [marks]
  (var mx -1)
  (each [_ m (ipairs marks)]
    (let [p m.opts.priority]
      (when (and p (> p mx)) (set mx p))))
  mx)

(fn test-every-fixture-priority-below-150 []
  (each [_ name (ipairs (fixture_names))]
    (let [buf (open_fixture name)
          mx (max_priority (h.marks buf))]
      (check (< mx vim.hl.priorities.diagnostics)
             (: "fixture %s: max mark priority %d should be below vim.hl.priorities.diagnostics (%d), NFR-I2"
                :format name mx vim.hl.priorities.diagnostics)))))

;; ---- mermaid priorities (overlay/pending/error/virt_lines row 140) --------

(fn scratch-md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn test-mermaid-priority-below-150 []
  (vim.fn.setenv :FAKE_OUT "")
  (vim.fn.setenv :FAKE_SLEEP "")
  (vim.fn.setenv :FAKE_ERR "")
  (vim.fn.setenv :FAKE_CODE "")
  (mada.setup {:anti_conceal false
               :mermaid {:cmd [fake-cmd] :timeout_ms 2000 :width_bucket 10}})
  (let [buf (scratch-md ["# D" "" "```mermaid" "graph LR" "  A --> B" "```" ""])]
    (check (h.wait_diagram buf) "expected the diagram job to complete")
    (let [mx (max_priority (h.marks buf))]
      (check (< mx vim.hl.priorities.diagnostics)
             (: "mermaid: max mark priority %d should be below vim.hl.priorities.diagnostics (%d), NFR-I2"
                :format mx vim.hl.priorities.diagnostics))))
  (mada.setup {}))

;; ---- AT-29: a diagnostic on a styled span draws over mada's styling ----

(fn test-at29-diagnostic-drawn-over-styling []
  "A diagnostic (vim.diagnostic.set, default underline highlighting) spanning
a MadaStrong word must be drawn over mada's own styling: checked the simple
way, via vim.inspect_pos, by comparing extmark priorities at that screen
position rather than parsing pixel/cell attributes."
  (mada.setup {:anti_conceal false})
  (set vim.o.columns 80)
  (let [buf (h.open :emphasis.md)]
    ;; Row 4 (0-based): \"**bold** and __bold too__.\"; \"bold\" is
    ;; MadaStrong over [2, 6) (inline.fnl's handle_emph, fixed to conceal the
    ;; whole delimiter run rather than one node - see highlighter_spec).
    (let [diag-ns (vim.api.nvim_create_namespace :mada-priority-spec-diag)]
      (vim.diagnostic.set diag-ns buf
                          [{:lnum 4
                            :col 2
                            :end_lnum 4
                            :end_col 6
                            :severity vim.diagnostic.severity.ERROR
                            :message :x}])
      (vim.cmd.redraw)
      (let [info (vim.inspect_pos buf 4 3)]
        (var mada_pri nil)
        (var diag_pri nil)
        (each [_ e (ipairs info.extmarks)]
          (when (= e.ns :mada) (set mada_pri e.opts.priority))
          (when (= e.opts.hl_group :DiagnosticUnderlineError)
            (set diag_pri e.opts.priority)))
        (check (not= mada_pri nil)
               "expected a mada extmark (MadaStrong) at that position")
        (check (not= diag_pri nil)
               "expected the diagnostic's DiagnosticUnderlineError extmark at that position")
        (check (> diag_pri mada_pri)
               (: "AT-29: the diagnostic's priority (%d) should be above mada's (%d), drawing over its styling"
                  :format diag_pri mada_pri))
        (vim.diagnostic.reset diag-ns buf)))))

[["every fixture: every mark's priority is below vim.hl.priorities.diagnostics (NFR-I2)"
  test-every-fixture-priority-below-150]
 ["mermaid marks (conceal_lines, pending/error/diagram row) stay below vim.hl.priorities.diagnostics"
  test-mermaid-priority-below-150]
 ["AT-29: a diagnostic on a styled span is drawn over mada's styling"
  test-at29-diagnostic-drawn-over-styling]]
