;; mada.screen - screen-row helpers shared by mada.tables and mada.mermaid:
;; S_r (screen rows a buffer row occupies, honouring `wrap`), the
;; wrap-emulating anchor-column function (a mid-byte column per screen row of
;; a line, for `virt_text_win_col = 0` overlays), per-character display width,
;; and padding a flat virt_text chunk-list to a display width. Moved out of
;; mada.tables (FR-R13) so mada.mermaid's own draw-over-source rendering (no
;; row ever hidden, OQ-1) can share the same anchor-column/S_r math; tables
;; output must stay byte-identical to before this move.

(local mark (require :mada.mark))

(local M {})

;; Per-character display width, memoized: the wrap-emulating anchor-column
;; function below (and mada.tables' own word-wrap path) calls this once per
;; character on every cache miss (FR-P3), so it is worth a fast path that
;; skips a Lua/C call entirely for plain text. Printable ASCII (0x20-0x7E) is
;; always 1 cell. Otherwise: tabs and other control characters go through
;; `strdisplaywidth` (honours 'tabstop', which `nvim_strwidth` does not --
;; measured: strdisplaywidth("\t") = 'tabstop', nvim_strwidth("\t") = 1);
;; anything else (wide/combining UTF-8 characters) goes through the cheaper
;; `nvim_strwidth`. Memoized per distinct character string, not per call: real
;; lines repeat the same non-ASCII characters.
(local char_width_memo {})

(fn M.char_width [ch]
  (let [b (ch:byte)]
    (if (and b (>= b 32) (<= b 126))
        1
        (let [cached (. char_width_memo ch)]
          (if cached
              cached
              (let [w (if (or (not b) (< b 32) (= b 127))
                          (vim.fn.strdisplaywidth ch)
                          (vim.api.nvim_strwidth ch))]
                (tset char_width_memo ch w)
                w))))))

(fn line_chars [line]
  "`line` split into one entry per UTF-8 character: {: text : bytestart}, 0-
based `bytestart`."
  (let [out []
        n (length line)]
    (var i 1)
    (while (<= i n)
      (let [b (line:byte i)
            len (if (< b 128) 1
                    (< b 224) 2
                    (< b 240) 3
                    4)]
        (table.insert out {:text (line:sub i (+ i len -1)) :bytestart (- i 1)})
        (set i (+ i len))))
    out))

(fn win_opt [win name]
  (let [(ok v) (pcall vim.api.nvim_get_option_value name {: win})]
    (if ok v nil)))

(fn breakat_set []
  (let [(ok s) (pcall vim.api.nvim_get_option_value :breakat {})
        bs {}]
    (when (and ok (= (type s) :string))
      (for [i 1 (length s)] (tset bs (s:sub i i) true)))
    bs))

(fn find_breakat [bset chars row_start i]
  "Latest index j in chars[row_start..i-1] whose character is a `breakat`
character, plus 1 (the `linebreak` break point); or `i` itself when none (a
word longer than a row hard-breaks)."
  (var found i)
  (var done false)
  (var j (- i 1))
  (while (and (>= j row_start) (not done))
    (when (. bset (. chars j :text))
      (set found (+ j 1))
      (set done true))
    (set j (- j 1)))
  found)

(fn emulate_wrap_starts [win buf line chars n width0]
  "1-based `chars` indices where each screen row of `line` starts, per
Neovim's own `wrap`/`linebreak`/`breakat`/`showbreak`/`breakindent` (a hard
wrap at the window text width; with `linebreak`, break after the last
`breakat` character when the next word does not fit; a word longer than a
row hard-breaks; continuation rows are narrower by `showbreak` and, with
`breakindent`, by the line's own indent)."
  (let [linebreak? (win_opt win :linebreak)
        breakindent? (win_opt win :breakindent)
        showbreak (or (win_opt win :showbreak) "")
        sb_w (mark.width showbreak)
        (ok tabstop) (pcall vim.api.nvim_get_option_value :tabstop {: buf})
        ts (if (and ok tabstop (> tabstop 0)) tabstop 8)
        bset (breakat_set)
        indent_w (if breakindent? (mark.width (or (line:match "^%s*") "")) 0)
        cont_width (math.max 1 (- width0 sb_w indent_w))
        starts [1]]
    (var col 0)
    (var width (math.max 1 width0))
    (var row_start 1)
    (var i 1)
    (while (<= i n)
      (let [c (. chars i)
            w (if (= c.text "\t") (- ts (% col ts)) (M.char_width c.text))]
        (if (and (> col 0) (> (+ col w) width))
            (let [bp (if (not linebreak?) i
                         (find_breakat bset chars row_start i))]
              (table.insert starts bp)
              (set row_start bp)
              (set width cont_width)
              (set col 0)
              (for [k row_start (- i 1)]
                (let [cc (. chars k)
                      ww (if (= cc.text "\t") (- ts (% col ts))
                             (M.char_width cc.text))]
                  (set col (+ col ww))))
              (set col (+ col w)))
            (set col (+ col w))))
      (set i (+ i 1)))
    starts))

(fn evenly_spaced_cols [chars n s_r]
  "Fallback anchor columns when the emulated row count does not match
`s_r`: `s_r` char-aligned midpoints spread evenly over `line`'s characters."
  (fcollect [k 1 s_r]
    (if (= n 0)
        0
        (. chars
           (math.max 1 (math.min n (+ 1 (math.floor (* (- k 0.5) (/ n s_r))))))
           :bytestart))))

(fn M.row_anchor_cols [win buf line s_r width0]
  "`s_r` 0-based byte columns, one per screen row of `line`, each the
midpoint byte of its emulated row span (char-aligned, tolerates small
emulation errors)."
  (let [chars (line_chars line)
        n (length chars)]
    (if (<= s_r 1)
        [(if (= n 0)
             0
             (. chars (math.max 1 (math.floor (/ (+ n 1) 2))) :bytestart))]
        (let [starts (emulate_wrap_starts win buf line chars n width0)]
          (if (= (length starts) s_r)
              (fcollect [k 1 s_r]
                (let [st (. starts k)
                      en (or (. starts (+ k 1)) (+ n 1))
                      mid (math.max st
                                    (math.min (- en 1)
                                              (math.floor (/ (+ st en) 2))))]
                  (. chars mid :bytestart)))
              (evenly_spaced_cols chars n s_r))))))

(fn M.s_r_for [win row]
  "Screen rows `row` occupies in `win` (`nvim_win_text_height`, exact:
honours `wrap`/`linebreak`/`showbreak`/`breakindent`; `.fill` excludes
virt_lines)."
  (let [t (vim.api.nvim_win_text_height win {:start_row row :end_row row})]
    (math.max 1 (- t.all t.fill))))

(fn chunks_width [line]
  (accumulate [w 0 _ c (ipairs line)]
    (+ w (mark.width (. c 1)))))

(fn M.pad_chunks_to [line width]
  "`line` (a flat virt_text chunk-list) padded on the right with spaces to
`width` display columns, so an overlay narrower than the window never lets
raw source show through to its right."
  (let [w (chunks_width line)]
    (if (< w width)
        (let [out (icollect [_ c (ipairs line)] c)]
          (table.insert out [(string.rep " " (- width w))])
          out)
        line)))

M
