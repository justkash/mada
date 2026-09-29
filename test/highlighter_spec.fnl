;; test.highlighter_spec - AT-19, AT-20, AT-21: treesitter.highlight modes
;; (FR-M10). Plus a collision guard (NFR-Q1-adjacent): the plugin's own
;; marks must fully account for what is shown on screen, so turning the
;; runtime highlighter on or off must never change the *text* (only its
;; colours).
;;
;; The runtime query normally conceals whole fence rows. Mada masks that
;; metadata only in an attached buffer's active highlighter, leaving other
;; buffers and the shared query unchanged.

(local h (require :helpers))
(local mada (require :mada))
(local state (require :mada.state))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn trim [s]
  (pick-values 1 (s:gsub "%s+$" "")))

(fn normalize [marks]
  "Strip opts.ns_id, as test.snapshot_spec does: it names the namespace by
creation order within this process, not part of a mark's meaning."
  (icollect [_ m (ipairs marks)]
    (let [opts (vim.deepcopy m.opts)]
      (tset opts :ns_id nil)
      {:row m.row :col m.col : opts})))

(fn fence_line_conceals [query root buf]
  (var count 0)
  (each [capture node metadata (query:iter_captures root buf)]
    (when (and (= (node:type) :fenced_code_block_delimiter)
               (or metadata.conceal_lines
                   (and (. metadata capture)
                        (. (. metadata capture) :conceal_lines))))
      (set count (+ count 1))))
  count)

(fn test-query-mask-scoped-and-restored []
  (mada.setup {:anti_conceal false :treesitter {:highlight true}})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["```lua" "print('ok')" "```"])
    (vim.api.nvim_win_set_buf 0 buf)
    (vim.treesitter.start buf :markdown)
    (let [instance (. vim.treesitter.highlighter.active buf)
          holder (instance:get_query :markdown)
          original (holder:query)
          parser (vim.treesitter.get_parser buf :markdown)
          tree (. (parser:parse) 1)
          root (tree:root)]
      (check (> (fence_line_conceals original root buf) 0)
             "precondition: the runtime query conceals fence rows")
      (set vim.bo.filetype :markdown)
      (check (= instance (. vim.treesitter.highlighter.active buf))
             "attach must preserve a user-started highlighter instance")
      (check (not= original (holder:query))
             "attach must wrap the buffer's Markdown query")
      (h.eq 0 (fence_line_conceals (holder:query) root buf)
            "attached highlighter must leave fence rows visible")
      (check (> (fence_line_conceals original root buf) 0)
             "original query metadata must remain intact")
      (let [other (vim.api.nvim_create_buf true false)]
        (vim.api.nvim_buf_set_lines other 0 -1 false ["```lua" :x "```"])
        (vim.treesitter.start other :markdown)
        (let [other-instance (. vim.treesitter.highlighter.active other)
              other-holder (other-instance:get_query :markdown)]
          (check (= original (other-holder:query))
                 "another buffer must keep the shared original query"))
        (vim.treesitter.stop other))
      (mada.disable buf)
      (check (= instance (. vim.treesitter.highlighter.active buf))
             "disable must preserve the user-started highlighter instance")
      (check (= original (holder:query))
             "disable must restore the original parsed query")
      (vim.treesitter.stop buf))))

(fn test-visible-fences-with-highlighter []
  (mada.setup {:anti_conceal false
               :code {:hide_fences false}
               :treesitter {:highlight true}})
  (set vim.o.columns 80)
  (set vim.o.lines 30)
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["```lua" "print('ok')" "```"])
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    (mada.render buf)
    (let [opening (. (vim.fn.screenpos 0 1 1) :row)
          closing (. (vim.fn.screenpos 0 3 1) :row)]
      (check (> opening 0) "opening fence must have a screen row")
      (check (> closing opening) "closing fence must have a screen row")
      (h.eq "```lua" (trim (h.screen_row opening 40))
            "hide_fences=false shows the opening fence and language with Tree-sitter")
      (h.eq "```" (trim (h.screen_row closing 40))
            "hide_fences=false shows the closing fence with Tree-sitter"))
    (mada.disable buf)))

;; ---- AT-19: "auto", no highlighter active ----

(fn test-at19-auto-starts-stops-matches-snapshot []
  (mada.setup {:anti_conceal false :treesitter {:highlight :auto}})
  (set vim.o.columns 80)
  (let [path :test/fixtures/headings.md
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (let [buf (h.open :headings.md)]
    (check (not= nil (. vim.treesitter.highlighter.active buf))
           "AT-19: the highlighter should start on attach (auto, none active)")
    (check (. (state.get buf) :started_ts)
           "AT-19: mada should record that it started the highlighter")
    ;; Same snapshot AT-18 already checks (test.snapshot_spec, same fixture,
    ;; same anti_conceal=false setup): the plugin's own namespace must be
    ;; identical whether or not a highlighter is running (it lives in its
    ;; own namespace).
    (h.snapshot :headings (normalize (h.marks buf)))
    (mada.disable buf)
    (check (= nil (. vim.treesitter.highlighter.active buf))
           "AT-19: :Mada disable should stop the highlighter mada started")))

;; ---- AT-20: highlighter already active (user-started), "auto" ----

(fn test-at20-user-highlighter-untouched-cursor-raw []
  (mada.setup {:anti_conceal true :treesitter {:highlight :auto}})
  (set vim.o.columns 80)
  (set vim.o.lines 20)
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["*em* text" "" :more])
    (vim.api.nvim_win_set_buf 0 buf)
    (vim.treesitter.start buf :markdown)
    (let [active-before (. vim.treesitter.highlighter.active buf)]
      (set vim.bo.filetype :markdown)
      (check (= false (. (state.get buf) :started_ts))
             "AT-20: mada must not claim it started an already-active highlighter")
      (check (= active-before (. vim.treesitter.highlighter.active buf))
             "AT-20: the highlighter instance must be unchanged (not restarted)")
      ;; Cursor starts at (1, 0): row 0 is anti-concealed from the first
      ;; render (events.enter_rendered reads the current cursor at attach).
      (h.eq "*em* text" (h.screen_row 1 9)
            "AT-20: the cursor row should show raw delimiters")
      (mada.disable buf)
      (check (not= nil (. vim.treesitter.highlighter.active buf))
             "AT-20: :Mada disable must not stop a highlighter mada did not start")
      (vim.treesitter.stop buf))))

;; ---- AT-21: false, never started ----

(fn test-at21-false-never-starts []
  (mada.setup {:treesitter {:highlight false} :anti_conceal false})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["# Heading" "" :para])
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    (check (= nil (. vim.treesitter.highlighter.active buf))
           "AT-21: no highlighter should ever start")
    (check (> (length (h.marks buf)) 0)
           "AT-21: the plugin's own rendering should be unaffected"))
  (mada.setup {}))

;; ---- collision guard: screen text, highlight=true vs false ----

(fn fixture_names []
  "Sorted basenames of test/fixtures/*.md, excluding reference.md and names
starting with mermaid (mermaid diagram text comes from the termaid backend,
not from this comparison)."
  (let [files (vim.fn.readdir :test/fixtures)
        names []]
    (each [_ f (ipairs files)]
      (when (and (f:match "%.md$") (not= f :reference.md)
                 (not (f:match :^mermaid)))
        (table.insert names (pick-values 1 (f:gsub "%.md$" "")))))
    (table.sort names)
    names))

(fn screen_grid [n width]
  (vim.cmd.redraw)
  (let [out []]
    (for [r 1 n]
      (let [chars []]
        (for [c 1 width] (table.insert chars (vim.fn.screenstring r c)))
        (table.insert out (table.concat chars))))
    out))

(fn render_fixture_grid [name mode]
  "A fresh scratch buffer (never a file-backed one reused across calls) with
`name`'s fixture text, attached with treesitter.highlight = `mode`, 80
columns, anti_conceal = false; returns its screen text, one string per
buffer row."
  (let [path (.. :test/fixtures/ name :.md)
        lines (vim.fn.readfile path)
        n (length lines)
        buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (mada.setup {:anti_conceal false :treesitter {:highlight mode}})
    (set vim.o.columns 80)
    (set vim.o.lines (math.max 60 (+ n 10)))
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    (mada.render buf)
    (screen_grid n 80)))

;; test/fixtures/links.md deliberately includes "[not a link] has no
;; definition." to exercise UR-3 ("only real syntax is styled"): mada's own
;; handle_ref_link (inline.fnl) checks link_reference_definitions before
;; concealing shortcut_link brackets, so it correctly leaves this one raw.
;; The bundled markdown_inline highlights.scm has no such check (a static
;; query cannot cross-reference definitions) and conceals every
;; shortcut_link's brackets unconditionally, so `treesitter.highlight = true`
;; hides "[not a link]" while `false` does not. Not a mada defect - the same
;; kind of unavoidable runtime-query divergence the task named for
;; `code.hide_fences = false` - so this fixture is excluded from the guard.
(local known_divergences
       {:links "runtime highlights.scm conceals every shortcut_link's brackets unconditionally (no reference-definition check); mada's own concealment is intentionally definition-aware (UR-3)"})

(fn test-collision-guard-screen-text-unchanged []
  (each [_ name (ipairs (fixture_names))]
    (when (not (. known_divergences name))
      (let [off (render_fixture_grid name false)
            on (render_fixture_grid name true)]
        (h.eq off on (.. "collision guard: screen text differs between treesitter.highlight = false and true for fixture "
                         name))))))

;; ---- "stop the highlighter" (FR-M10, FR-M11): real runtime ftplugin/user
;; input, over RPC (OQ-5, architecture §15) ----
;;
;; `filetype plugin on` makes Neovim 0.12's own ftplugin/markdown.lua run
;; `vim.treesitter.start()` on every markdown buffer, same as interactive
;; use; `:syntax on` is what makes the legacy regex-syntax finding below
;; reproducible (runtime/syntax/syntax.vim's `syntaxset` FileType autocmd,
;; which stopping a highlighter re-triggers, only exists once `:syntax on`
;; has run - see the task report for the full mechanism). Neither `-u NONE`
;; child in test/events_spec.fnl / test/mermaid_spec.fnl runs `:syntax on`,
;; so this spec starts its own children instead of reusing theirs.

(fn start-child []
  (let [ch (vim.fn.jobstart [:nvim
                             :--embed
                             :--headless
                             :-n
                             :-i
                             :NONE
                             :-u
                             :NONE] {:rpc true})]
    (vim.rpcrequest ch :nvim_exec_lua "vim.o.columns = 80
vim.o.lines = 30
vim.o.swapfile = false
local rtp = os.getenv('MADA_RTP')
vim.opt.runtimepath:prepend(rtp)
vim.cmd.source(rtp .. '/plugin/mada.lua')
vim.cmd('syntax on')
vim.cmd('filetype plugin on')" [])
    ch))

(fn exec [ch code ?args]
  (vim.rpcrequest ch :nvim_exec_lua code (or ?args [])))

(fn sync [ch]
  "Reach the child's idle loop: deferred autocommands and vim.schedule
callbacks (the highlighter recheck in events.fnl's M.attach) fire before
this call returns (OQ-5)."
  (vim.rpcrequest ch :nvim_eval :1))

(fn edit [ch path]
  (exec ch "local path = ...\nvim.cmd.edit(path)" [path])
  (sync ch))

(fn setup [ch lua_opts]
  (exec ch (.. "require('mada').setup(" lua_opts ")"))
  (sync ch))

(fn highlighter-active? [ch]
  (exec ch
        "return vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil"))

(fn syntax-of [ch]
  (exec ch "return vim.bo.syntax"))

(fn test-default-stops-runtime-highlighter-and-syntax-restores-on-disable []
  (let [ch (start-child)]
    (edit ch :test/fixtures/headings.md)
    (check (= false (highlighter-active? ch))
           "default config (highlight=false): the runtime ftplugin's highlighter should be stopped")
    (h.eq "" (syntax-of ch)
          "default config (highlight=false): stopping the highlighter must not leave legacy regex syntax running")
    (exec ch "require('mada').disable(0)")
    (sync ch)
    (check (= true (highlighter-active? ch))
           ":Mada disable should restart the highlighter mada stopped, restoring the original state")
    (vim.fn.jobstop ch)))

(fn test-true-ensures-highlighter-active []
  (let [ch (start-child)]
    (setup ch "{treesitter = {highlight = true}}")
    (edit ch :test/fixtures/headings.md)
    (check (= true (highlighter-active? ch))
           "highlight=true: a highlighter must be active")
    (vim.fn.jobstop ch)))

(fn test-explicit-query-set-preserved []
  (let [ch (start-child)]
    (setup ch "{treesitter = {highlight = true}}")
    (exec ch
          "vim.treesitter.query.set('markdown', 'highlights', '(fenced_code_block (fenced_code_block_delimiter) @markup.raw.block (#set! conceal_lines \"\"))')")
    (edit ch :test/fixtures/code.md)
    (check (exec ch
                 "local b = vim.api.nvim_get_current_buf(); local h = vim.treesitter.highlighter.active[b]; return h and h:get_query('markdown'):query() ~= vim.treesitter.query.get('markdown', 'highlights')")
           "an explicit query.set should be wrapped only in the active instance")
    (exec ch "require('mada').disable(0)")
    (check (exec ch
                 "local b = vim.api.nvim_get_current_buf(); local h = vim.treesitter.highlighter.active[b]; return h and h:get_query('markdown'):query() == vim.treesitter.query.get('markdown', 'highlights')")
           "disable should restore the exact explicit query.set object")
    (vim.fn.jobstop ch)))

(fn test-auto-over-limit-stops-runtime-highlighter []
  (let [ch (start-child)]
    (setup ch "{treesitter = {highlight = 'auto', auto_max_lines = 3}}")
    (edit ch :test/fixtures/headings.md)
    (check (= false (highlighter-active? ch))
           "auto over auto_max_lines: the runtime ftplugin's highlighter should be stopped")
    (vim.fn.jobstop ch)))

[["AT-19: auto starts on attach, stops on disable, marks match the AT-18 snapshot"
  test-at19-auto-starts-stops-matches-snapshot]
 ["runtime fence conceal metadata is masked only for the attached buffer and restored on disable"
  test-query-mask-scoped-and-restored]
 ["hide_fences=false shows opening and closing fence text with Tree-sitter"
  test-visible-fences-with-highlighter]
 ["AT-20: user-started highlighter left alone, cursor row raw"
  test-at20-user-highlighter-untouched-cursor-raw]
 ["AT-21: treesitter.highlight = false never starts a highlighter"
  test-at21-false-never-starts]
 ["collision guard: highlighter on/off does not change screen text (defaults)"
  test-collision-guard-screen-text-unchanged]
 ["default config stops the real runtime ftplugin highlighter (and legacy syntax), :Mada disable restores it"
  test-default-stops-runtime-highlighter-and-syntax-restores-on-disable]
 ["highlight=true ensures a highlighter is active under the real runtime ftplugin"
  test-true-ensures-highlighter-active]
 ["an explicit user query.set remains shared and is restored on disable"
  test-explicit-query-set-preserved]
 ["highlight=\"auto\" over auto_max_lines stops the real runtime ftplugin's highlighter"
  test-auto-over-limit-stops-runtime-highlighter]]
