;; test.health_spec - FR-H, architecture §11, AT-10's health part: runs
;; :checkhealth mada with a fake-termaid cmd, and with a missing cmd, and
;; checks the health buffer's OK/ERROR lines.

(local h (require :helpers))
(local config (require :mada.config))

(local fake-cmd (.. (vim.fn.getcwd) :/test/bin/fake-termaid))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn contains? [s needle]
  (not= nil (s:find needle 1 true)))

(fn any-line? [lines pred]
  (var found false)
  (each [_ l (ipairs lines)] (when (pred l) (set found true)))
  found)

(fn checkhealth-lines []
  "Run :checkhealth mada and return the resulting health buffer's lines.
Wipes any previous health buffer first so each call starts from a clean
report (:checkhealth reuses a buffer named health://)."
  (each [_ b (ipairs (vim.api.nvim_list_bufs))]
    (when (= (. vim.bo b :filetype) :checkhealth)
      (pcall vim.api.nvim_buf_delete b {:force true})))
  (vim.cmd "checkhealth mada")
  (var out [])
  (each [_ b (ipairs (vim.api.nvim_list_bufs))]
    (when (= (. vim.bo b :filetype) :checkhealth)
      (set out (vim.api.nvim_buf_get_lines b 0 -1 false))))
  out)

(fn test-fake-termaid-ok []
  (config.setup {:mermaid {:cmd [fake-cmd]}})
  (let [lines (checkhealth-lines)]
    (check (any-line? lines (fn [l] (contains? l "OK Neovim")))
           "expected an OK line for the Neovim version")
    (check (any-line? lines
                      (fn [l] (contains? l "OK markdown parser loadable")))
           "expected an OK line for the markdown parser")
    (check (any-line? lines
                      (fn [l]
                        (contains? l "OK markdown_inline parser loadable")))
           "expected an OK line for the markdown_inline parser")
    (check (any-line? lines
                      (fn [l] (contains? l "OK termaid executable found")))
           "expected an OK line for the termaid executable")
    (check (any-line? lines
                      (fn [l]
                        (contains? l "OK termaid smoke render succeeded")))
           "expected an OK line for the termaid smoke render")
    (check (any-line? lines
                      (fn [l]
                        (contains? l "OK no conflicting Markdown renderer")))
           "expected an OK line for no conflicting renderer")
    (check (any-line? lines (fn [l] (contains? l "config: enabled=true")))
           "expected a config summary line")))

(fn test-missing-termaid-error []
  (config.setup {:mermaid {:cmd [:/nonexistent/mada-missing-termaid]}})
  (let [lines (checkhealth-lines)]
    (check (any-line? lines
                      (fn [l]
                        (and (contains? l :ERROR)
                             (contains? l "termaid executable not found"))))
           "expected an ERROR line for the missing termaid executable")
    ;; A missing backend must not also try (and fail) the smoke render.
    (check (not (any-line? lines (fn [l] (contains? l "termaid smoke render"))))
           "no smoke-render line expected when the executable itself is missing"))
  (config.setup {}))

(fn test-conflict-warns []
  (tset package.loaded :render-markdown {})
  (let [lines (checkhealth-lines)]
    (check (any-line? lines
                      (fn [l]
                        (and (contains? l :WARNING)
                             (contains? l "conflicting Markdown renderer"))))
           "expected a WARNING line when a conflicting renderer is loaded"))
  (tset package.loaded :render-markdown nil)
  (config.setup {}))

[["checkhealth mada: fake-termaid present, OK lines" test-fake-termaid-ok]
 ["checkhealth mada: missing cmd, ERROR line" test-missing-termaid-error]
 ["checkhealth mada: conflicting renderer warns" test-conflict-warns]]
