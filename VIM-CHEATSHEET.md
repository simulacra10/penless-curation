# Vim Cheat Sheet for `inbox.tsv` (Penless Curation — C++ Edition)

This file format is: `date<TAB>type<TAB>url<TAB>title<TAB>tags`.  
**Tip:** Prefer `#`‑prefixed tags (e.g. `#YouTube #linux`).

---

## Basic Navigation
- `f<Tab>` → jump to next tab (next column)
- `;` / `,` → repeat last `f` search forward/backward
- `:set list listchars=tab:»·,trail:·` → show tabs clearly
- `:set nowrap` / `:set wrap` → toggle line wrapping for long titles

---

## Search & Delete
- Delete all lines matching `youtube`:
  ```
  :g/youtube/d
  ```
- Keep only lines with `fedora` (delete all others):
  ```
  :v/fedora/d
  ```

---

## Sorting & Deduplication
- Sort by type (2nd column):
  ```
  :sort r /^\([^	]*\)	\([^	]*\)	/
  ```
- Deduplicate by URL (3rd column) using awk:
  ```
  :%!awk '!seen[$3]++'
  ```

---

## Tag Editing (recommend `#`-prefixed tokens)
- Add tag `#bushcraft` to all lines:
  ```
  :%s/$/ #bushcraft/
  ```
- Add tag only to lines with YouTube in the URL:
  ```
  :g/youtube/s/$/ #YouTube/
  ```
- Replace tag `#yt` with `#YouTube`:
  ```
  :%s/\<#yt\>/#YouTube/g
  ```

---

## Block Editing (Visual Block)
- Add text at same column across lines:
  1. Move cursor, press `Ctrl-v`
  2. Select down (`j`)
  3. Press `I` (insert), type text, then `<Esc>`

- Append text at line ends:
  1. `Ctrl-v` to select
  2. `$A newtag<Esc>`

---

## Grep Inside Vim (with ripgrep)
Add to `~/.vimrc`:
```vim
set grepprg=rg\ --vimgrep
command! -nargs=+ Rg silent grep! <args> | copen
```
Usage:
```
:Rg youtube.com
```
Open results: `:copen`, move with `:cn` / `:cp`.

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
