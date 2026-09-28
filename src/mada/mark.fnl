;; mada.mark - mark-record constructors, overlay_fit, display width.
;;
;; A mark record is {: row : col : opts : shifting}. `row`/`col` are 0-based
;; buffer positions; `opts` is passed straight to `nvim_buf_set_extmark`;
;; `shifting` is true for marks that change the column mapping on their row
;; (conceal, overlay, inline, conceal_line) so anti-conceal can drop them on
;; the cursor row. Every constructor sets `invalidate = true` and
;; `undo_restore = false` (FR-T5). `overlay_fit` returns a *list* of mark
;; records (one or two); every other constructor returns a single record.

(local M {})

(local base {:invalidate true :undo_restore false})

(fn record [row col opts shifting]
  {: row : col : opts : shifting})

(fn ascii_only? [s]
  "True when every byte of `s` is printable ASCII (0x20-0x7E): no tabs,
other control characters or multi-byte UTF-8 sequences, so its display
width always equals its byte length."
  (not (s:find "[^ -~]")))

(fn M.width [s]
  "Display width of `s` (tabs and wide/combining characters honoured).
Printable-ASCII-only strings (the common case for overlay_fit's spans and
similar short strings) skip the `strdisplaywidth` call entirely: their
width is always their byte length."
  (if (ascii_only? s) (length s) (vim.fn.strdisplaywidth s)))

(fn M.bytes_for_width [s w]
  "Byte length of the longest prefix of `s` whose display width is <= w."
  (let [n (vim.fn.strchars s)]
    (var acc 0)
    (var chars 0)
    (var stop false)
    (while (and (< chars n) (not stop))
      (let [ch (vim.fn.strcharpart s chars 1)
            cw (vim.fn.strdisplaywidth ch)]
        (if (> (+ acc cw) w)
            (set stop true)
            (do
              (set acc (+ acc cw))
              (set chars (+ chars 1))))))
    (vim.str_byteindex s chars)))

(fn M.hl [row col end_col group priority]
  "Highlight range [col, end_col) on `row`. Non-shifting."
  (record row col
          (vim.tbl_extend :force base {: end_col :hl_group group : priority})
          false))

(fn M.line_hl [row group priority]
  "Whole-row background highlight. Non-shifting."
  (record row 0 (vim.tbl_extend :force base {:line_hl_group group : priority})
          false))

(fn M.conceal [row col end_col priority ?replacement]
  "Conceal [col, end_col) on `row`, optionally replaced by one character.
Shifting."
  (record row col (vim.tbl_extend :force base
                                  {: end_col
                                   :conceal (or ?replacement "")
                                   : priority}) true))

(fn M.overlay [row col end_col text group priority]
  "Draw `text` over [col, end_col) on `row`. Shifting."
  (record row col (vim.tbl_extend :force base
                                  {: end_col
                                   :virt_text [[text group]]
                                   :virt_text_pos :overlay
                                   : priority}) true))

(fn M.overlay_win_col [row col chunks priority]
  "Draw `chunks` (a flat virt_text chunk-list) as an overlay pinned to window
text column 0, anchored at [row, col]: it lands on whichever wrapped screen
row of `row` contains byte `col` (verified: `virt_text_win_col` draws at a
fixed window column of the screen row the anchor's byte falls on). Used to
draw a pipe table's laid-out grid lines directly over the source row's own
screen rows, one overlay per screen row (FR-R13). Shifting."
  (record row col (vim.tbl_extend :force base
                                  {:virt_text chunks
                                   :virt_text_pos :overlay
                                   :virt_text_win_col 0
                                   : priority}) true))

(fn M.inline [row col text group priority]
  "Insert `text` as virtual text at `col` on `row`, without concealing
anything. Shifting (it changes what occupies screen columns from `col` on)."
  (record row col (vim.tbl_extend :force base
                                  {:virt_text [[text group]]
                                   :virt_text_pos :inline
                                   : priority}) true))

(fn M.inline_chunks [row col chunks priority]
  "Insert `chunks` (a list of virt_text chunks, each `[text group]` where
`group` may be a single group, a list of groups, or omitted) as inline
virtual text at `col` on `row`, without concealing anything. Shifting."
  (record row col (vim.tbl_extend :force base
                                  {:virt_text chunks
                                   :virt_text_pos :inline
                                   : priority}) true))

(fn M.virt_lines [row lines priority ?above ?shifting]
  "Attach `lines` (a list of chunk-lists, each chunk `[text group]`) below
`row` (or above it when `?above` is true). Non-shifting unless `?shifting`
is true (a table row's wrapped cell lines, dropped on the cursor row like
any other shifting mark, FR-R13)."
  (record row 0 (vim.tbl_extend :force base
                                {:virt_lines lines
                                 :virt_lines_above (or ?above false)
                                 : priority})
          (or ?shifting false)))

(fn M.conceal_line [row priority]
  "Hide `row` entirely (`conceal_lines`). Shifting."
  (record row 0 (vim.tbl_extend :force base {:conceal_lines "" : priority})
          true))

(fn M.right_align [row text group priority]
  "Right-aligned virtual text on `row`. Non-shifting."
  (record row 0 (vim.tbl_extend :force base
                                {:virt_text [[text group]]
                                 :virt_text_pos :right_align
                                 : priority}) false))

(fn M.overlay_fit [row col end_col span_text replacement group priority]
  "Overlay `replacement` over the source span [col, end_col) on `row`, whose
text is `span_text`. Never exceeds the span's display width: overflow
becomes an adjacent `inline` mark after `end_col`; underflow conceals the
remaining source bytes. A span containing a tab falls back to a plain
highlight (overlays never span a tab). Returns a list of mark records."
  (if (span_text:find "\t")
      [(M.hl row col end_col group priority)]
      (let [span-w (M.width span_text)
            rep-w (M.width replacement)]
        (if (= rep-w span-w)
            [(M.overlay row col end_col replacement group priority)]
            (if (< rep-w span-w)
                (let [tail-col (+ col (M.bytes_for_width span_text rep-w))]
                  [(M.overlay row col tail-col replacement group priority)
                   (M.conceal row tail-col end_col priority)])
                (let [fit-bytes (M.bytes_for_width replacement span-w)
                      shown (replacement:sub 1 fit-bytes)
                      rest (replacement:sub (+ fit-bytes 1))]
                  [(M.overlay row col end_col shown group priority)
                   (M.inline row end_col rest group priority)]))))))

M
