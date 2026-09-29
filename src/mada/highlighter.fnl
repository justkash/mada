;; Keep Markdown fence rows visible while mada uses them as code padding.
;; Neovim's bundled highlights query gives delimiter and language captures
;; conceal_lines and conceal metadata. Wrap only this buffer's active query:
;; the shared parsed query and injected-language queries remain untouched.

(local M {})
(local patches {})
(local ns (vim.api.nvim_create_namespace :nvim.treesitter.highlighter))

(fn fence_capture? [node]
  (when node
    (let [kind (node:type)
          parent (node:parent)]
      (or (and (= kind :fenced_code_block_delimiter) parent
               (= (parent:type) :fenced_code_block))
          (and (= kind :language) parent (= (parent:type) :info_string)
               (let [grandparent (parent:parent)]
                 (and grandparent (= (grandparent:type) :fenced_code_block))))))))

(fn without_fence_conceal [capture node metadata]
  (if (and metadata (fence_capture? node)
           (or metadata.conceal_lines metadata.conceal
               (and (. metadata capture)
                    (or (. (. metadata capture) :conceal_lines)
                        (. (. metadata capture) :conceal)))))
      (let [copy (vim.tbl_extend :force {} metadata)
            capture_meta (. copy capture)]
        (tset copy :conceal_lines nil)
        (tset copy :conceal nil)
        (when capture_meta
          (let [nested (vim.tbl_extend :force {} capture_meta)]
            (tset nested :conceal_lines nil)
            (tset nested :conceal nil)
            (tset copy capture nested)))
        copy)
      metadata))

(fn refresh [buf instance]
  "Drop persistent conceal_lines marks from the old query and make the
highlighter rebuild its row state on the next redraw."
  (when (vim.api.nvim_buf_is_valid buf)
    (vim.api.nvim_buf_clear_namespace buf ns 0 -1)
    (set instance._conceal_checked {})
    (if vim.api.nvim__redraw
        (vim.api.nvim__redraw {: buf :flush false})
        (vim.cmd.redraw))))

(fn M.restore [buf]
  "Restore this buffer's original parsed query if our wrapper is still in
place. A query installed later by another owner is left alone."
  (let [patch (. patches buf)]
    (when patch
      (when (= patch.holder._query patch.proxy)
        (set patch.holder._query patch.original)
        (when (= (. vim.treesitter.highlighter.active buf) patch.instance)
          (refresh buf patch.instance)))
      (tset patches buf nil))))

(fn M.install [buf]
  "Suppress only runtime fence conceal metadata in the active
Markdown highlighter instance; keep its syntax captures and identity."
  (let [instance (. vim.treesitter.highlighter.active buf)]
    ;; _query is a Neovim highlighter implementation detail. If its shape
    ;; changes, leave the active highlighter alone.
    (when (and instance (= (type instance.get_query) :function))
      (let [holder (instance:get_query :markdown)
            patch (. patches buf)]
        (when (and holder (= (type holder.query) :function)
                   (not (and patch (= patch.instance instance)
                             (= patch.holder holder)
                             (= holder._query patch.proxy))))
          (M.restore buf)
          (let [original (holder:query)]
            (when (and original (= holder._query original)
                       (= (type original.iter_captures) :function))
              (let [proxy (setmetatable {:iter_captures (fn [_ ...]
                                                          (let [iter (original:iter_captures ...)]
                                                            (fn [...]
                                                              (let [(capture node
                                                                             metadata
                                                                             query_match
                                                                             tree) (iter ...)]
                                                                (values capture
                                                                        node
                                                                        (without_fence_conceal capture
                                                                          node
                                                                          metadata)
                                                                        query_match
                                                                        tree)))))}
                                        {:__index (fn [_ key] (. original key))})]
                (set holder._query proxy)
                (tset patches buf {: instance : holder : original : proxy})
                (refresh buf instance)))))))))

M
