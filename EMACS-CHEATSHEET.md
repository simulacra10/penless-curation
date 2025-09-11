# Emacs Cheat Sheet for `inbox.tsv` (Penless Curation — C++ Edition)

File format: `date<TAB>type<TAB>url<TAB>title<TAB>tags`  
**Tip:** Prefer tags with a leading `#` (e.g. `#YouTube #linux`).

---

## Basic Navigation
- `C-s` / `C-r` → Incremental search forward/backward
- `M-f` / `M-b` → Move forward/backward a word
- `C-a` / `C-e` → Beginning / end of line
- `M-m` → First non-whitespace character
- `M-g g` → Go to line number

Show tabs visibly:
```elisp
(setq whitespace-style '(face tabs tab-mark trailing))
(global-whitespace-mode 1)
```

---

## Editing Lines
- `C-k` → Kill line
- `C-y` → Yank (paste)
- `C-/` or `C-x u` → Undo

Delete all lines matching regex:
```
M-x flush-lines RET youtube RET
```
Keep only lines matching regex:
```
M-x keep-lines RET fedora RET
```

---

## Sorting & Deduplication
- Mark region (`C-SPC`, move cursor)
- `M-x sort-fields RET 2 RET` → sort by 2nd field (type)
- `M-x sort-fields RET 3 RET` → sort by 3rd field (URL)
- `M-x delete-duplicate-lines` → remove duplicates in region

---

## Tag Editing (recommend `#`-prefixed tokens)
- Add a tag at end of lines:
```
M-x query-replace-regexp RET $ RET  #bushcraft RET
```
- Add tag only to lines with `youtube` in the URL:
```
M-x query-replace-regexp RET \(youtube[^\t]*\)$ RET \1 #YouTube RET
```
- Replace tag everywhere:
```
M-x query-replace-regexp RET \b#yt\b RET #YouTube RET
```

---

## Rectangle (Column) Editing
- `C-x SPC` → Start rectangular selection
- `C-x r t` → Insert text in rectangle
- `C-x r k` → Kill rectangle
- `C-x r y` → Yank rectangle

---

## Macros
- Record: `F3` … edits … `F4`
- Replay: `F4`
- Apply macro to region: `C-x C-k r`

---

## Search with Grep / Ripgrep
- `M-x rgrep RET youtube.com RET *.tsv RET .`
- Navigate matches with `n` / `p`

---

## CSV/TSV Mode
Enable `csv-mode` for better column handling:
```elisp
(use-package csv-mode
  :ensure t
  :mode ("\\.tsv\\'" . csv-mode))
```
Then use:
- `M-x csv-align-fields` → align columns
- `M-x csv-sort-fields` → sort by column

---

## Digest Format (for reference)

Digest bullets (rendered by `curate digest`) use **no date** and look like:
```md
- [domain](url) — *kind* — Title — #Tag1 #Tag2
```
Example:
```md
- [youtube.com](https://www.youtube.com/watch?v=b40RW38xMXs) — *video* — WHOA!! Bodycam EXPOSES this "GOOD COP" as Being REALLY BAD after Walking Away from Auditor - YouTube — #YouTube
```
