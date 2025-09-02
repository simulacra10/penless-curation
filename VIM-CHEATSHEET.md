
# Vim Cheat Sheet for `inbox.tsv` (Penless Curation)

This file format is: `date<TAB>type<TAB>url<TAB>title<TAB>tags`.

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

## Tag Editing
- Add tag `bushcraft` to all lines:
  ```
  :%s/$/ bushcraft/
  ```
- Add tag only to YouTube lines:
  ```
  :g/youtube/s/$/ yt/
  ```
- Replace tag `yt` with `youtube`:
  ```
  :%s/\<yt\>/youtube/g
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

## Quick Macros
- Record macro `a`: `qa`
- Do edits on first line
- Stop: `q`
- Apply to next 10 lines: `10@a`

---

## Grep Inside Vim (requires ripgrep)
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

## TSV File Settings (Optional)
Create `~/.vim/after/ftplugin/tsv.vim` with:
```vim
setlocal noexpandtab
setlocal nowrap
setlocal list listchars=tab:»·,trail:·
```

---

✅ Keep it plain: fast edits, instant fixes, no bloat.
