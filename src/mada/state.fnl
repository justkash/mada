;; mada.state - per-buffer state (own module: breaks require cycles).
;;
;; state[buf] = {
;;   cfg,                                   resolved config captured at attach
;;   raw        = bool,
;;   tick       = changedtick at the last parsing render,
;;   cursor     = cursor row last seen in the current window,
;;   clean      = { [win] = {a, b} },        rows rendered in win since edit
;;   blocks     = { [anchor] = {diagram?, err?, job?} },
;;   started_ts = bool,                      plugin started the highlighter
;;   stopped_ts = bool,                      plugin stopped a highlighter
;;                                            that was running (restore it
;;                                            on detach)
;; }

(local M {})

(local buffers {})
(local ns (vim.api.nvim_create_namespace :mada))
(local anchor_ns (vim.api.nvim_create_namespace :mada.anchor))

(fn M.ns []
  "The namespace holding every visible mark."
  ns)

(fn M.anchor_ns []
  "The namespace holding one invisible anchor mark per Mermaid block (§8.2)."
  anchor_ns)

(fn M.get [buf]
  "Return buf's state, or nil if not attached."
  (. buffers buf))

(fn M.ensure [buf cfg]
  "Return buf's state, creating it with `cfg` if it does not exist yet."
  (or (. buffers buf) (let [s {: cfg
                               :raw false
                               :tick -1
                               :cursor -1
                               :clean {}
                               :blocks {}
                               :started_ts false
                               :stopped_ts false}]
                        (tset buffers buf s)
                        s)))

(fn M.clear [buf]
  "Release buf's state."
  (tset buffers buf nil))

(fn M.all []
  "Return the buf -> state table (read-only use; do not mutate directly)."
  buffers)

M
