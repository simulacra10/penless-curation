# Penless Curation v4 — Comprehensive README

A plain-text system for capturing links, tagging them, and rolling them into monthly digests.  
No databases, no bloat: just `bash`, `tsv`, and `markdown`.  

---

## 📂 Project Layout

```
penless-curation-v4/
├── curate.sh              # main script (all commands live here)
├── inbox.tsv              # your raw capture inbox (tab-separated)
├── archive.tsv            # optional archive of processed items
├── rules.tsv              # domain → type/tags mapping
├── notes/                 # generated digests (Markdown)
├── templates/
│   └── monthly_header.md  # inserted at top of each digest
└── README-v4.md           # this guide
```

### File explanations
- **`curate.sh`**: main entrypoint. Handles adding, digesting, searching, rules, imports/exports, and TUI.
- **`inbox.tsv`**: everything you capture lands here. Format:  
  ```
  date<TAB>type<TAB>url<TAB>title<TAB>tags
  ```
- **`archive.tsv`**: when you run `digest --archive`, items for that month are moved here to keep `inbox.tsv` fresh.
- **`rules.tsv`**: lets you define domain-based rules so classification and tags are automatic.  
  Example line:  
  ```
  youtube.com    video    yt
  ```
- **`notes/`**: your digests. Every `digest` run creates Markdown files (news/blogs/videos/links/all).
- **`templates/monthly_header.md`**: optional boilerplate added to top of digests (edit or delete as you like).
- **`README-v4.md`**: this guide.

---

## 🚀 Quick Start

```bash
# unpack
unzip penless-curation-v4.zip -d ~/penless-curation
cd ~/penless-curation/penless-curation-v4

# set up directories/files
./curate.sh init

# add a rule so YouTube is always video + yt tag
./curate.sh rules add youtube.com video yt

# capture a link
./curate.sh add "https://www.youtube.com/watch?v=L1S0SiBuJN8" bushcraft

# see inbox
cat inbox.tsv

# build this month’s digest
./curate.sh digest

# view
less notes/all-2025-09.md
```

---

## 🔑 Core Commands

### Initialize
```bash
./curate.sh init
```
Creates `inbox.tsv`, `archive.tsv`, `rules.tsv`, and directories if missing.

---

### Add
```bash
./curate.sh add URL [tags...]
./curate.sh add -t TYPE URL [tags...]
```
- Fetches `<title>` (via lynx or curl).
- Detects type: `news`, `blog`, `video`, `link` (rules may override).
- Appends to `inbox.tsv`.

Examples:
```bash
./curate.sh add "https://fedoramagazine.org/post" linux fedora
./curate.sh add -t blog "https://substack.com/somepost" newsletter
```

---

### Clipboard Add
```bash
./curate.sh clip [tags...]
```
Requires `xclip`. Pulls URL from clipboard and adds it.

---

### Digest
```bash
./curate.sh digest [YYYY-MM] [--archive] [--hugo] [--hugo-section SECTION]
```
Creates monthly digests in `notes/`. Options:
- `--archive` → move processed lines to `archive.tsv`.
- `--hugo` → add YAML front matter for Hugo static sites.
- `--hugo-section` → set section in Hugo front matter.

Files generated:
- `notes/news-YYYY-MM.md`
- `notes/blogs-YYYY-MM.md`
- `notes/videos-YYYY-MM.md`
- `notes/links-YYYY-MM.md`
- `notes/all-YYYY-MM.md`

---

### Search
```bash
./curate.sh search PATTERN
```
Case-insensitive grep across inbox.

---

### Rules
```bash
./curate.sh rules list
./curate.sh rules add <domain> [type] [tags...]
./curate.sh rules test <url>
```
- Rules auto-apply type and tags by domain suffix.
- Example:
  ```bash
  ./curate.sh rules add reuters.com news finance wire
  ./curate.sh add "https://www.reuters.com/article/xyz"
  ```
  → saved as type `news` with tags `finance wire`.

---

### Import
```bash
./curate.sh import file.tsv|file.csv [--format tsv|csv|auto]
```
- Reads 5 columns: `date, type, url, title, tags`.
- Fills missing fields (auto-type, today’s date).
- Applies rules.

---

### Export
```bash
./curate.sh export [YYYY-MM] > out.json
```
- Exports inbox (or given month) as JSON.

---

### TUI (fzf)
```bash
./curate.sh tui
```
Requires `fzf`. Interactive menu for add/search/digest/rules.

---

### Install Dependencies
```bash
./curate.sh install-deps
```
- Fedora/RHEL: `dnf install curl lynx xclip`
- Debian/Ubuntu: `apt install curl lynx xclip`

---

## 🛠 Maintenance Tips

- **Deleting mistakes**: just edit `inbox.tsv` in `vim`/`emacs` and remove the line.
- **Backup/versioning**:  
  ```bash
  git init
  git add inbox.tsv rules.tsv notes/
  git commit -m "curation updates"
  ```
- **Archiving**: run `digest --archive` monthly to keep `inbox.tsv` small.
- **Cleaning rules**: edit `rules.tsv` if you need to fix or remove a rule (tab-separated fields).
- **Tweaks**: adjust `templates/monthly_header.md` for headers/logos/boilerplate.

---

## 💡 Philosophy
- **Plain text first**: everything is TSV/Markdown.
- **Low friction capture**: fastest possible `add` flow.
- **Power in editors**: you can clean/rewrite with Vim/Emacs or any script.
- **No lock-in**: easy to grep, sort, share, or publish.
