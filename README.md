# Penless Curation — C++ Edition

A plain‑text workflow for capturing links to `inbox.tsv`, tagging them, and rolling them into weekly (or custom range) digests.  
No databases, no runtimes — just a tiny C++20 CLI, TSV, and Markdown/HTML.

---

## ✅ What’s new in this edition

- Rewritten as a **single C++20 binary**: `curate`
- **Digest format** (per item): no date, domain as link text, kind, then title and tags:
  ```md
  - [youtube.com](https://www.youtube.com/watch?v=b40RW38xMXs) — *video* — WHOA!! Bodycam ... — #YouTube
  ```
- **Default output**: `curate digest` writes into `digests/<range>.md` (or `.html` with `-pd`)
- Use `-o -` to force **stdout**

---

## 📦 Requirements

- A C++20 compiler (GCC 12+/Clang 14+). Example build on Fedora:
  ```bash
  g++ -std=c++20 -O2 -o curate curate.cpp
  ```

Optional:
- `pandoc` (only if you want to post‑process Markdown yourself; **not required** because `-pd` emits HTML)
- `git` for versioning/backups

---

## 📂 Project Layout

```
penless-curation/
├── curate.cpp             # source (this repo)
├── curate                 # compiled binary
├── inbox.tsv              # raw capture inbox (tab-separated; 5 cols)
├── templates/
│   └── header.md          # optional header inserted at top of digests
├── digests/               # generated digests (default output)
└── archive/               # created by 'clear-inbox' for rotating inbox
```

### File formats

- **`inbox.tsv`** — **five** tab‑separated columns:
  ```
  date<TAB>type<TAB>url<TAB>title<TAB>tags
  ```
  Tags are stored as tokens, typically **prefixed with `#`** (e.g. `#YouTube #linux`).  
  The `curate add` command will auto‑prefix `#` for you; if you manually edit, prefer including the `#`.

- **Digest (.md/.html)** — each entry is rendered as:
  ```md
  - [domain](url) — *kind* — Title — #Tag1 #Tag2
  ```

---

## 🚀 Quick Start

```bash
# Build
g++ -std=c++20 -O2 -o curate curate.cpp

# (Optional) choose a home folder; default is current directory
export CURATE_HOME="$HOME/penless-curation"

# First run conveniences
mkdir -p "$CURATE_HOME/templates" "$CURATE_HOME/digests"
[ -f "$CURATE_HOME/templates/header.md" ] || printf "# Weekly Curation\n\n" > "$CURATE_HOME/templates/header.md"
[ -f "$CURATE_HOME/inbox.tsv" ] || : > "$CURATE_HOME/inbox.tsv"

# Capture a link
./curate add "https://www.youtube.com/watch?v=b40RW38xMXs" #YouTube

# Build this week's digest (Markdown written to digests/2025-W37.md)
./curate digest -gt

# HTML instead (written to digests/2025-W37.html)
./curate digest -gt -pd

# Custom date range (auto filename digests/2025-09-01_to_2025-09-07.md)
./curate digest --start 2025-09-01 --end 2025-09-07

# Force stdout (legacy behavior)
./curate digest -gt -pd -o -
```

---

## 🧰 Commands

```text
curate add <url> [tags...] [--title "..."] [--date YYYY-MM-DD]
curate digest [-gt|--group-tags] [--tags-only] [-pd]
              [--week YYYY-Www | --start YYYY-MM-DD --end YYYY-MM-DD]
              [--no-header] [-o <path>|-]
curate clear-inbox [--archive-dir <dir>]
curate list [--limit N] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
curate help | -h | --help
```

### `add`
- Appends a line to `inbox.tsv` (5 columns).  
- Type is auto‑detected from URL (`video`, `tweet`, `post`, `thread`, `hn`, `code`, `pdf`, `article`).  
- Tags you pass without `#` are auto‑prefixed on write.

Examples:
```bash
./curate add "https://substack.com/p/example" #Newsletter #AI
./curate add "https://github.com/user/repo" --title "Cool lib" #C++
./curate add "https://example.com" #tag1 tag2               # becomes "#tag1 #tag2"
```

### `digest`
- Builds a digest for a **week** (default: current ISO week) or a **custom range**.  
- Default output location if `-o` not specified:
  - `digests/<YYYY-Www>.md` (Markdown) or
  - `digests/<YYYY-Www>.html` (with `-pd`)
- For custom ranges: `digests/YYYY-MM-DD_to_YYYY-MM-DD.md`

Useful flags:
- `-gt, --group-tags` → add a “By Tag” section
- `--tags-only` → only the “By Tag” section (skip “All Items”)
- `-pd` → emit self‑contained HTML (no external CSS/JS)
- `--no-header` → don’t include `templates/header.md`
- `-o -` → force stdout

### `clear-inbox`
- Rotates `inbox.tsv` into `archive/inbox-<timestamp>.tsv` and creates a fresh empty `inbox.tsv`.
- Use `--archive-dir <dir>` to override archive location.

### `list`
- Prints lines from `inbox.tsv` with optional filtering by date range and limit.

---

## 📝 Digest Entry Format (Important)

The digest uses **no date** in each bullet. The exact format is:

```
- [domain](url) — *kind* — Title — #Tag1 #Tag2
```

Example:

```
- [youtube.com](https://www.youtube.com/watch?v=b40RW38xMXs) — *video* — WHOA!! Bodycam EXPOSES this "GOOD COP" as Being REALLY BAD after Walking Away from Auditor - YouTube — #YouTube
```

---

## 🛠 Tips

- Keep edits to `inbox.tsv` simple—use **tabs** between the five columns.
- Prefer tags that start with `#` (e.g. `#YouTube`). The CLI will add `#` automatically for `add`, but manual edits should include it too for clean rendering.
- Customize `templates/header.md` to include any boilerplate or intro text.

---

## 💡 Philosophy

- **Plain text** first: portable, future‑proof.
- **Fast capture**, low friction.
- **Your editor is power**: use Vim/Emacs for batch refactors.
- **No lock‑in**: TSV/Markdown are universal.


---

---

## 🖥️ Cross‑platform builds

`curate.cpp` is portable and builds on Linux, macOS, and Windows.

### macOS

**Dependencies**
- Xcode Command Line Tools (Apple Clang) _or_ Homebrew GCC 12+

**Install toolchain**
```bash
# Option A: Apple Clang (recommended)
xcode-select --install

# Option B: Homebrew GCC
brew install gcc
```

**Build**
```bash
# Apple Clang
clang++ -std=c++20 -O2 -o curate curate.cpp

# Or Homebrew GCC (name may vary, e.g., g++-14)
g++-14 -std=c++20 -O2 -o curate curate.cpp
```

> If you see a link error about `<filesystem>` on very old GCC, try adding `-lstdc++fs` (not needed on modern compilers).

### Windows

Two options: **MSVC (Visual Studio 2022 / Build Tools)** or **MSYS2 MinGW‑w64**.

#### Option A: MSVC (Visual Studio)

**Dependencies**
- Microsoft C++ Build Tools or Visual Studio 2022 with C++ workload

**Build (Developer Command Prompt)**
```bat
cl /std:c++20 /O2 /EHsc curate.cpp
```
Produces `curate.exe` in the current directory.

> Note: The source includes a portable time shim that uses `localtime_s` on Windows and `localtime_r` elsewhere—no changes required.

#### Option B: MSYS2 MinGW‑w64 (GNU toolchain)

**Dependencies**
- MSYS2 with MinGW‑w64 packages

**Install toolchain**
1. Install MSYS2 from https://www.msys2.org/
2. Open the **MSYS2 MinGW x64** shell and run:
   ```bash
   pacman -S --needed mingw-w64-x86_64-gcc
   ```

**Build (in MinGW shell)**
```bash
g++ -std=c++20 -O2 -o curate.exe curate.cpp
```
> If `<filesystem>` link errors appear on older GCC, add `-lstdc++fs`:
> ```bash
> g++ -std=c++20 -O2 -o curate.exe curate.cpp -lstdc++fs
> ```

### WSL (Windows Subsystem for Linux)

If you prefer Linux toolchains on Windows, use Ubuntu (or similar) in WSL:
```bash
sudo apt update && sudo apt install -y g++
g++ -std=c++20 -O2 -o curate curate.cpp
```

---

## 🔎 Verifying your build

```bash
./curate help
./curate add "https://example.com" #Example
./curate digest -gt
```
Check `./digests/` for the generated file.


## 🔎 Verifying your build

```bash
./curate help
./curate add "https://example.com" #Example
./curate digest -gt
```
Check `./digests/` for the generated file.
