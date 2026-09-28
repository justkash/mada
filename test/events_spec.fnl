;; test.events_spec - AT-3, AT-5, AT-6, AT-16, AT-23: events that only fire
;; from real input. `CursorMoved`, `WinScrolled` and `TextChanged` never
;; fire from `nvim_feedkeys` in a `-l` script (OQ-5, architecture §15), so
;; these tests drive a real child Neovim over RPC instead.

(local h (require :helpers))
(local mada (require :mada))
(local config (require :mada.config))

(fn start-child []
  "Start a child Neovim with --embed over RPC and load the built plugin,
mirroring interactive startup."
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
vim.cmd('filetype on')" [])
    ch))

(fn sync [ch]
  "Reach the child's idle loop so deferred autocommands (CursorMoved,
WinScrolled, TextChanged) fire before this call returns (OQ-5)."
  (vim.rpcrequest ch :nvim_eval :1))

(fn input [ch keys]
  (vim.rpcrequest ch :nvim_input keys))

(fn input-sync [ch keys]
  (input ch keys)
  (sync ch))

(fn exec [ch code ?args]
  (vim.rpcrequest ch :nvim_exec_lua code (or ?args [])))

(fn edit [ch path]
  (exec ch "local path = ...\nvim.cmd.edit(path)" [path])
  (sync ch))

(fn stats [ch]
  (exec ch "return require('mada.render').stats()"))

(fn reset-stats [ch]
  (exec ch "require('mada.render').reset_stats()"))

(fn changedtick [ch]
  (exec ch "return vim.api.nvim_buf_get_changedtick(0)"))

(fn marks-of [ch]
  "{: row : col : opts} for every mark in mada's namespace, sorted by
(row, col); mirrors test.helpers' M.marks for the current buffer of `ch`."
  (let [raw (exec ch "local ns = require('mada.state').ns()
local raw = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {details = true})
local out = {}
for _, m in ipairs(raw) do
  table.insert(out, {row = m[2], col = m[3], opts = m[4]})
end
return out")]
    (table.sort raw
                (fn [a b]
                  (if (= a.row b.row) (< a.col b.col) (< a.row b.row))))
    raw))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn has-h1? [ms row]
  "true if `ms` has the H1 text highlight (MadaH1) on `row`. Row-specific:
headings.md has two H1 headings, so a buffer-wide check would not notice
one going missing."
  (var found false)
  (each [_ m (ipairs ms)]
    (when (and (= m.row row) (= m.opts.hl_group :MadaH1)) (set found true)))
  found)

(fn has-conceal? [ms row]
  (var found false)
  (each [_ m (ipairs ms)]
    (when (and (= m.row row) (not= m.opts.conceal nil)) (set found true)))
  found)

(fn has-shifting? [ms row]
  "true if any mark on `row` carries conceal, an overlay virt_text, or
conceal_lines (the marks anti-conceal removes from the cursor row)."
  (var found false)
  (each [_ m (ipairs ms)]
    (when (and (= m.row row)
               (or (not= m.opts.conceal nil) (not= m.opts.conceal_lines nil)
                   (and m.opts.virt_text (= m.opts.virt_text_pos :overlay))))
      (set found true)))
  found)

(fn assert-no-duplicates [ms msg]
  (var dup nil)
  (let [n (length ms)]
    (for [i 1 n]
      (for [j (+ i 1) n]
        (when (and (not dup) (vim.deep_equal (. ms i) (. ms j)))
          (set dup [i j])))))
  (when dup
    (error (.. msg ": duplicate marks at indices " (. dup 1) " and " (. dup 2))
           0)))

(fn with-child [f]
  "Run `f` with a fresh child, always stopping it afterwards (even on
failure)."
  (let [ch (start-child)
        (ok err) (pcall f ch)]
    (pcall vim.fn.jobstop ch)
    (when (not ok) (error err 0))))

(fn test-at3 []
  (with-child (fn [ch]
                (edit ch :test/fixtures/headings.md)
                (reset-stats ch)
                (input-sync ch :i)
                (input-sync ch :<Esc>)
                (let [ms (marks-of ch)
                      st (stats ch)]
                  (check (> (length ms) 0)
                         "AT-3: expected marks present right after <Esc>, with no timer wait")
                  (check (> st.renders 0)
                         "AT-3: expected the render counter to increase")))))

(fn test-at5 []
  (with-child (fn [ch]
                ;; Exercise anti-conceal with a concealed heading marker.
                (exec ch
                      "require('mada').setup({ headings = { conceal_markers = true } })")
                (edit ch :test/fixtures/headings.md)
                ;; Cursor starts on row 0 ("# Heading 1"). Move off, then back onto
                ;; it, so the move under test is a deliberate move off a heading row.
                (input-sync ch :j)
                (input-sync ch :k)
                (reset-stats ch)
                (let [before (stats ch)]
                  (input-sync ch :j)
                  (let [after (stats ch)
                        ms (marks-of ch)]
                    (h.eq before.parses after.parses
                          "AT-5: parses must not change on a cursor move")
                    (check (> after.renders before.renders)
                           "AT-5: renders must increase on a cursor move")
                    (check (has-conceal? ms 0)
                           "AT-5: heading row 0 should regain its conceal mark once the cursor leaves it")
                    (check (not (has-shifting? ms 1))
                           "AT-5: the new cursor row (1) must carry no shifting marks"))))))

(fn build-long-buffer [ch]
  "Write a 600-line scratch file, alternating ATX heading / paragraph rows,
and return its path."
  (exec ch "local tmp = vim.fn.tempname() .. '.md'
local lines = {}
for i = 1, 600 do
  if i % 2 == 1 then
    lines[#lines + 1] = '# Heading ' .. i
  else
    lines[#lines + 1] = 'paragraph line ' .. i
  end
end
vim.fn.writefile(lines, tmp)
return tmp"))

(fn scroll-step-check [ch]
  "0-based viewport range (± margin 20, clamped), the first heading row in
it missing a mark (or nil), and render.stats() at this step."
  (exec ch
        "local w0 = vim.fn.line('w0') - 1
local wd = vim.fn.line('w$') - 1
local total = vim.api.nvim_buf_line_count(0)
local margin = 20
local lo = math.max(0, w0 - margin)
local hi = math.min(total - 1, wd + margin)
local ns = require('mada.state').ns()
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
local present = {}
for _, m in ipairs(marks) do present[m[2]] = true end
local start = lo
if start % 2 ~= 0 then start = start + 1 end
local missing = nil
for r = start, hi, 2 do
  if not present[r] then
    missing = r
    break
  end
end
local st = require('mada.render').stats()
return {lo = lo, hi = hi, missing = missing, parses = st.parses, renders = st.renders}"))

(fn far-check [ch furthest]
  "{: bad} where `bad` is the 0-based row of a heading beyond `furthest`
that unexpectedly carries a mark, or nil. Wrapped in a table because a bare
`return nil` from nvim_exec_lua decodes as `vim.NIL`, not Fennel nil, over
msgpack-RPC; a table field simply absent decodes as real nil."
  (exec ch "local furthest = ...
local total = vim.api.nvim_buf_line_count(0)
local ns = require('mada.state').ns()
local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
local present = {}
for _, m in ipairs(marks) do present[m[2]] = true end
local start = furthest + 1
if start % 2 ~= 0 then start = start + 1 end
local bad = nil
for r = start, total - 1, 2 do
  if present[r] then
    bad = r
    break
  end
end
return {bad = bad}" [furthest]))

(fn test-at6 []
  (with-child (fn [ch]
                (let [tmp (build-long-buffer ch)]
                  (edit ch tmp)
                  (reset-stats ch)
                  (var furthest -1)
                  (var prev-parses 0)
                  (var max-delta 0)
                  (for [i 1 500]
                    (input-sync ch :<C-e>)
                    (let [r (scroll-step-check ch)]
                      (check (= r.missing nil)
                             (.. "AT-6: step " i ": heading row "
                                 (tostring r.missing)
                                 " missing marks in viewport range [" r.lo ", "
                                 r.hi "]"))
                      (set furthest (math.max furthest r.hi))
                      (let [delta (- r.parses prev-parses)]
                        (set max-delta (math.max max-delta delta))
                        (set prev-parses r.parses))
                      (when (= 0 (% i 50))
                        (let [fr (far-check ch furthest)]
                          (check (= fr.bad nil)
                                 (.. "AT-6: step " i ": heading row "
                                     (tostring fr.bad) " beyond furthest range "
                                     furthest " unexpectedly carries marks"))))))
                  (print (.. "AT-6: max parses delta per scroll step = "
                             max-delta))
                  (check (< max-delta 10)
                         (.. "AT-6: parses grew too fast per step (max delta "
                             max-delta
                             "); expected roughly constant, not scaling with buffer size"))))))

(fn test-at16 []
  (with-child (fn [ch]
                (edit ch :test/fixtures/headings.md)
                ;; Row 0 ("# Heading 1") is the row `dd` deletes. headings.md has a
                ;; second H1 further down, so the check must be row-specific.
                (let [marks-before (marks-of ch)
                      tick0 (changedtick ch)]
                  (check (has-h1? marks-before 0)
                         "AT-16 precondition: row 0 should be the H1 heading before dd")
                  (input-sync ch :dd)
                  (let [tick1 (changedtick ch)
                        marks-after-dd (marks-of ch)]
                    (h.eq (+ tick0 1) tick1
                          "AT-16: dd should bump changedtick by exactly 1 (only Neovim's own edit)")
                    (check (not (has-h1? marks-after-dd 0))
                           "AT-16: the deleted heading's MadaH1 mark should be gone from row 0")
                    (input-sync ch :u)
                    (let [tick2 (changedtick ch)
                          marks-after-undo (marks-of ch)]
                      ;; Bare Neovim (no plugin) also bumps changedtick by 2
                      ;; for a single-line undo, confirmed separately; the
                      ;; check is that the plugin adds nothing on top.
                      (h.eq (+ tick1 2) tick2
                            "AT-16: undo should bump changedtick by exactly 2, matching bare Neovim (only Neovim's own edit)")
                      (check (has-h1? marks-after-undo 0)
                             "AT-16: the restored heading's MadaH1 mark should be present on row 0")
                      (assert-no-duplicates marks-after-undo :AT-16)
                      (h.eq marks-before marks-after-undo
                            "AT-16: marks after undo should equal marks before the delete")))))))

(fn test-at23 []
  (with-child (fn [ch]
                (edit ch :test/fixtures/headings.md)
                (input-sync ch :i)
                (let [r0 (stats ch)]
                  (check (= 0 (length (marks-of ch)))
                         "AT-23: namespace should be empty right after entering Insert")
                  (input-sync ch :<C-o>zz)
                  (check (= 0 (length (marks-of ch)))
                         "AT-23: namespace should stay empty after <C-o>zz")
                  (input-sync ch "<C-o>:echo 1<CR>")
                  (check (= 0 (length (marks-of ch)))
                         "AT-23: namespace should stay empty after <C-o>:echo 1<CR>")
                  (input-sync ch :<C-n>)
                  (input-sync ch :<C-e>)
                  (check (= 0 (length (marks-of ch)))
                         "AT-23: namespace should stay empty after opening and closing the completion menu")
                  (let [r1 (stats ch)]
                    (h.eq r0.renders r1.renders
                          "AT-23: render counter should not change across the Insert-mode round-trip"))
                  (input-sync ch :<Esc>)))))

(fn count-autocmds [ch group]
  (exec ch "local group = ...
local ok, cmds = pcall(vim.api.nvim_get_autocmds, {group = group})
if not ok then return 0 end
return #cmds" [group]))

(fn test-autocmds-persist []
  "Bug 0 regression: a callback that ends in a tail call to `log.guard`
returns its ok flag (true), and Neovim deletes an autocommand whose Lua
callback returns truthy after it fires. Every autocommand in both the
`mada` and `mada.<buf>` groups must still exist after two full i/<Esc>
round trips and several cursor moves."
  (with-child (fn [ch]
                (edit ch :test/fixtures/headings.md)
                (let [buf (exec ch "return vim.api.nvim_get_current_buf()")
                      global-before (count-autocmds ch :mada)
                      buf-before (count-autocmds ch (.. :mada. buf))]
                  (check (> global-before 0)
                         "precondition: the mada augroup should have autocommands")
                  (check (> buf-before 0)
                         "precondition: the mada.<buf> augroup should have autocommands")
                  (input-sync ch :i)
                  (input-sync ch :<Esc>)
                  (input-sync ch :j)
                  (input-sync ch :k)
                  (input-sync ch :i)
                  (input-sync ch :<Esc>)
                  (input-sync ch :j)
                  (input-sync ch :k)
                  (input-sync ch :j)
                  (let [global-after (count-autocmds ch :mada)
                        buf-after (count-autocmds ch (.. :mada. buf))]
                    (h.eq global-before global-after
                          "the mada augroup lost autocommands: a callback returned truthy and Neovim deleted it")
                    (h.eq buf-before buf-after
                          "the mada.<buf> augroup lost autocommands: a callback returned truthy and Neovim deleted it"))))))

(fn test-split-inherits-rendered-opts []
  "Bug 1 regression (UR-6): `:split` of a rendered window copies mada's own
local conceallevel/concealcursor. The new window's WinEnter must save the
window's *global* values (the true pre-mada ones inherited from the source
window), not mada's own 2/\"\", or `:Mada disable` restores the wrong value."
  (vim.api.nvim_set_option_value :conceallevel 1 {:scope :global})
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false ["# Heading" "" :para])
    (vim.api.nvim_win_set_buf 0 buf)
    (let [win1 (vim.api.nvim_get_current_win)]
      (vim.api.nvim_set_option_value :conceallevel 0 {:scope :local :win win1})
      (config.setup {})
      (set vim.bo.filetype :markdown)
      (h.eq 2
            (vim.api.nvim_get_option_value :conceallevel
                                           {:scope :local :win win1})
            "win1 should be rendered (conceallevel 2) before split")
      (vim.cmd.split)
      (let [win2 (vim.api.nvim_get_current_win)]
        (h.eq 2
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win2})
              "win2 should inherit mada's conceallevel 2 by copy right after :split")
        (mada.disable buf)
        (h.eq 0
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win1})
              "win1 should restore its true original conceallevel (0)")
        (h.eq 1
              (vim.api.nvim_get_option_value :conceallevel
                                             {:scope :local :win win2})
              "win2 should restore the window's pre-mada *global* conceallevel (1), not mada's own 2")
        (vim.api.nvim_win_close win2 true))))
  (vim.api.nvim_set_option_value :conceallevel 0 {:scope :global}))

[["AT-3: <Esc> renders synchronously, no timer wait" test-at3]
 ["AT-5: cursor move off a heading re-renders without parsing" test-at5]
 ["AT-6: 500-step scroll keeps the viewport rendered, parses roughly constant per step"
  test-at6]
 ["AT-16: dd then undo restores marks without duplicates or extra changedtick bumps"
  test-at16]
 ["AT-23: Insert-mode round trip keeps the namespace empty and the render counter unchanged"
  test-at23]
 ["Bug 0: autocommands survive i/<Esc> round trips and cursor moves (no self-deletion)"
  test-autocmds-persist]
 ["Bug 1 (UR-6): :split of a rendered window saves the window's global conceallevel, not mada's own"
  test-split-inherits-rendered-opts]]
