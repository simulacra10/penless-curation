#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# curate.sh - Plain text curation tool
#
# Copyright (c) 2025 Norman Bauer
#
# Licensed under the MIT License. You may obtain a copy of the License at:
#     https://opensource.org/licenses/MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# -----------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INBOX="${ROOT_DIR}/inbox.tsv"
ARCHIVE="${ROOT_DIR}/archive.tsv"
NOTES_DIR="${ROOT_DIR}/notes"
TEMPLATES_DIR="${ROOT_DIR}/templates"
HEADER_TPL="${TEMPLATES_DIR}/monthly_header.md"
RULES="${ROOT_DIR}/rules.tsv"

usage() {
  cat <<'USAGE'
Usage:
  ./curate.sh init
  ./curate.sh add [-t TYPE] [--no-title] URL [TAGS...]
  ./curate.sh clip [TAGS...]
  ./curate.sh digest [YYYY-MM | YYYY-Www] [--weekly] [--archive] [--hugo] [--hugo-section SECTION]
  ./curate.sh search <pattern>
  ./curate.sh install-deps
  ./curate.sh export [YYYY-MM]
  ./curate.sh import <file.tsv|file.csv> [--format auto|tsv|csv]
  ./curate.sh rules [list|add|test] ...
  ./curate.sh tui
  ./curate.sh help

Notes:
  - TYPE ∈ {news, blog, video, link}
  - inbox.tsv columns: date<TAB>type<TAB>url<TAB>title<TAB>tags
  - rules.tsv columns: domain<TAB>type<TAB>tags
USAGE
}

ensure_dirs() {
  mkdir -p "$NOTES_DIR" "$TEMPLATES_DIR"
  [[ -f "$INBOX" ]] || touch "$INBOX"
  [[ -f "$ARCHIVE" ]] || touch "$ARCHIVE"
  [[ -f "$RULES" ]] || touch "$RULES"
  if [[ ! -f "$HEADER_TPL" ]]; then
    cat > "$HEADER_TPL" <<'HDR'
<!-- Monthly/Weekly Digest Header -->

# Captain Contrary’s Digest

Each entry was hand-picked and tagged for easy searching later.

---
HDR
  fi
}

is_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_type() {
  local url="$1"
  shopt -s nocasematch
  if [[ "$url" =~ (youtube\.com|youtu\.be|vimeo\.com|rumble\.com|odysee\.com|tiktok\.com) ]]; then echo "video"; return; fi
  if [[ "$url" =~ (substack\.com|medium\.com|ghost\.org|wordpress\.com|write\.as|bearblog\.dev|blogspot\.com|hashnode\.dev|dev\.to) ]]; then echo "blog"; return; fi
  if [[ "$url" =~ (reuters\.com|apnews\.com|ap\.news|bloomberg\.com|wsj\.com|nytimes\.com|washingtonpost\.com|ft\.com|axios\.com|npr\.org|bbc\.com|theguardian\.com|aljazeera\.com) ]]; then echo "news"; return; fi
  echo "link"
}

# -------- Title helpers --------
html_title_curl() {
  local url="$1" raw
  raw="$(curl -Lfs --max-time 6 "$url" || true)"
  printf "%s" "$raw" | tr '\n' ' ' | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/p' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

html_title_lynx() {
  local url="$1"
  lynx -dump -nolist "$url" 2>/dev/null | awk 'NR==1{print; exit}'
}

best_title() {
  local url="$1" title=""
  if is_cmd lynx; then title="$(html_title_lynx "$url")"; fi
  if [[ -z "$title" ]] && is_cmd curl; then title="$(html_title_curl "$url")"; fi
  if [[ -z "$title" ]]; then
    local d="${url#*://}"; d="${d%%/*}"
    title="$d"
  fi
  printf "%s" "$title"
}

sanitize_field() {
  local s="$1"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"
  printf "%s" "$s"
}

# -------- Domain parsing & rules --------
url_domain() {
  local url="$1" d="${url#*://}"
  d="${d%%/*}"; d="${d%%:*}"
  printf "%s" "$d"
}

apply_rules() {
  local url="$1"; local cur_type="$2"; local tags_in="$3"
  local dom; dom="$(url_domain "$url")"
  local rule_type=""; local rule_tags=""
  if [[ -s "$RULES" ]]; then
    while IFS=$'\t' read -r rdom rtype rtags; do
      [[ -z "${rdom:-}" ]] && continue
      rdom="${rdom##[[:space:]]}"; rdom="${rdom%%[[:space:]]}"
      rtype="${rtype##[[:space:]]}"; rtype="${rtype%%[[:space:]]}"
      rtags="${rtags##[[:space:]]}"; rtags="${rtags%%[[:space:]]}"
      if [[ "$dom" == *"$rdom" ]]; then
        rule_type="$rtype"; rule_tags="$rtags"; break
      fi
    done < "$RULES"
  fi
  local out_type="$cur_type"
  [[ -n "$rule_type" ]] && out_type="$rule_type"
  local out_tags="$tags_in"
  if [[ -n "$rule_tags" ]]; then
    if [[ -n "$out_tags" ]]; then out_tags="$out_tags $rule_tags"; else out_tags="$rule_tags"; fi
  fi
  echo "$out_type|$out_tags"
}

# -------- Rendering helpers --------
render_md_list() {
  awk -F'\t' '
  function domain(u,  d) { sub(/^https?:\/\//,"",u); split(u,a,"/"); d=a[1]; return d }
  {
    date=$1; type=$2; url=$3; title=$4; tags=$5;
    if (title == "" ) title = domain(url);
    tagstr = (tags != "" ? " [" tags "]" : "");
    printf("- %s — [%s](%s) — *%s*%s\n", date, title, url, type, tagstr);
  }'
}

write_front_matter() {
  local outfile="$1"; local title="$2"; local section="$3"
  local now; now="$(date -Iseconds)"
  {
    echo "---"
    echo "title: \"$title\""
    echo "date: \"$now\""
    echo "draft: false"
    echo "type: digest"
    if [[ -n "$section" ]]; then echo "section: \"$section\""; fi
    echo "---"
    echo
  } >> "$outfile"
}

write_digest() {
  # period_id: YYYY-MM (monthly) or YYYY-Www (weekly)
  # mode: "monthly" or "weekly"; for weekly, provide start_date/end_date inclusive
  local period_id="$1"
  local kind="$2"
  local hugo="$3"
  local section="$4"
  local mode="${5:-monthly}"
  local start_date="${6:-}"
  local end_date="${7:-}"

  local outfile
  if [[ "$kind" == "all" ]]; then
    outfile="${NOTES_DIR}/all-${period_id}.md"
  else
    outfile="${NOTES_DIR}/${kind}s-${period_id}.md"
  fi

  : > "$outfile"

  if [[ "$hugo" == "1" ]]; then
    local title_kind
    case "$kind" in
      news)  title_kind="News" ;;
      blog)  title_kind="Blogs" ;;
      video) title_kind="Videos" ;;
      link)  title_kind="Links" ;;
      all)   title_kind="All Items" ;;
    esac
    write_front_matter "$outfile" "${title_kind} ${period_id}" "$section"
  fi

  if [[ -s "$HEADER_TPL" ]]; then cat "$HEADER_TPL" >> "$outfile"; fi

  local title_kind
  case "$kind" in
    news)  title_kind="News" ;;
    blog)  title_kind="Blogs" ;;
    video) title_kind="Videos" ;;
    link)  title_kind="Links" ;;
    all)   title_kind="All Items" ;;
  esac
  printf "# %s %s\n\n" "$title_kind" "$period_id" >> "$outfile"

  if [[ "$mode" == "weekly" && -n "$start_date" && -n "$end_date" ]]; then
    if [[ "$kind" == "all" ]]; then
      awk -F'\t' -v s="$start_date" -v e="$end_date" '$1>=s && $1<=e' "$INBOX" | render_md_list >> "$outfile"
    else
      awk -F'\t' -v s="$start_date" -v e="$end_date" -v k="$kind" '$1>=s && $1<=e && $2==k' "$INBOX" | render_md_list >> "$outfile"
    fi
  else
    if [[ "$kind" == "all" ]]; then
      awk -F'\t' -v m="$period_id" '$1 ~ m' "$INBOX" | render_md_list >> "$outfile"
    else
      awk -F'\t' -v m="$period_id" -v k="$kind" '$1 ~ m && $2==k' "$INBOX" | render_md_list >> "$outfile"
    fi
  fi
  echo "Wrote: $outfile"
}

# -------- Commands --------
cmd_init() {
  # Check for Python3 (needed for weekly digest date math)
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required but not found."
    echo "Please install it and rerun ./curate.sh init"
    echo
    echo "Fedora/RHEL:"
    echo "  sudo dnf install -y python3"
    echo
    echo "Debian/Ubuntu:"
    echo "  sudo apt install -y python3"
    exit 1
  fi

  ensure_dirs
  touch "$INBOX" "$ARCHIVE" "$RULES"
  mkdir -p "$NOTES_DIR" "$TEMPLATES_DIR"
  if [[ ! -s "$HEADER_TPL" ]]; then
    echo "<!-- Monthly/Weekly Digest Header -->" > "$HEADER_TPL"
  fi
  echo "Initialized at $ROOT_DIR"
}

cmd_add() {
  ensure_dirs
  local type=""; local no_title="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--type) type="${2:-}"; shift 2;;
      --no-title) no_title="1"; shift;;
      -h|--help) usage; exit 0;;
      -*) echo "Unknown flag: $1" >&2; exit 1;;
      *) break;;
    esac
  done
  if [[ $# -lt 1 ]]; then echo "Missing URL" >&2; usage; exit 1; fi
  local url="$1"; shift || true
  local tags="${*:-}"

  # Determine type (manual wins)
  if [[ -z "$type" ]]; then type="$(detect_type "$url")"; fi

  # Apply domain rules (manual type still wins; we just merge tags)
  local merged; merged="$(apply_rules "$url" "$type" "$tags")"
  local new_type="${merged%%|*}"
  local new_tags="${merged#*|}"
  if [[ -n "$type" && "$type" != "$(detect_type "$url")" ]]; then
    new_type="$type"
  fi

  local title=""
  if [[ "$no_title" == "0" ]]; then title="$(best_title "$url")"; fi
  title="$(sanitize_field "$title")"
  new_tags="$(sanitize_field "$new_tags")"

  local date_iso; date_iso="$(date -u +%Y-%m-%d)"
  printf "%s\t%s\t%s\t%s\t%s\n" "$date_iso" "$new_type" "$url" "$title" "$new_tags" >> "$INBOX"
  echo "Added: $url"
}

cmd_clip() {
  ensure_dirs
  if ! is_cmd xclip; then
    echo "xclip not found. Install it to use 'clip' (Fedora: sudo dnf install -y xclip)"; exit 1
  fi
  local url; url="$(xclip -o -selection clipboard)"
  [[ -n "$url" ]] || { echo "Clipboard is empty."; exit 1; }
  cmd_add "$url" "$@"
}

write_week_range_python() {
  # Input: period_id like 2025-W36; outputs week_start and week_end (Mon..Sun)
  local period_id="$1"
  local start_py
  start_py="$(python3 - <<'PY' "$period_id"
import sys, datetime
s = sys.argv[1]               # e.g., 2025-W36
y, w = s.split('-W')
d = datetime.date.fromisocalendar(int(y), int(w), 1)  # Monday
print(d.isoformat())
PY
)"
  local week_start="$start_py"
  local week_end
  week_end="$(date -d "${week_start} +6 days" +%Y-%m-%d)"
  printf "%s|%s" "$week_start" "$week_end"
}

cmd_digest() {
  ensure_dirs
  local period_id=""
  local archive="0"
  local hugo="0"
  local section=""
  local weekly="0"
  local week_start=""
  local week_end=""

  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) archive="1"; shift;;
      --hugo) hugo="1"; shift;;
      --hugo-section) section="${2:-}"; shift 2;;
      --weekly) weekly="1"; shift;;
      *) args+=("$1"); shift;;
    esac
  done
  set -- "${args[@]:-}"

  if [[ $# -ge 1 ]]; then
    if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
      period_id="$1"   # monthly explicit
    elif [[ "$1" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
      weekly="1"; period_id="$1"
    else
      period_id=""
    fi
  fi

  if [[ "$weekly" == "1" ]]; then
    [[ -n "$period_id" ]] || period_id="$(date +%G-W%V)"
    if ! command -v python3 >/dev/null 2>&1; then
      echo "Error: python3 is required for --weekly date math."; exit 1
    fi
    local range; range="$(write_week_range_python "$period_id")"
    week_start="${range%%|*}"; week_end="${range#*|}"

    for k in news blog video link all; do
      write_digest "$period_id" "$k" "$hugo" "$section" "weekly" "$week_start" "$week_end"
    done
  else
    [[ -n "$period_id" ]] || period_id="$(date +%Y-%m)"
    for k in news blog video link all; do
      write_digest "$period_id" "$k" "$hugo" "$section" "monthly"
    done
  fi

  if [[ "$archive" == "1" ]]; then
    tmp="$(mktemp)"
    if [[ "$weekly" == "1" ]]; then
      awk -F'\t' -v s="$week_start" -v e="$week_end" '$1>=s && $1<=e {print > "'"$ARCHIVE"'"; next} {print > "'"$tmp"'"}' "$INBOX"
      mv "$tmp" "$INBOX"
      echo "Archived entries for $period_id ($week_start..$week_end) -> $ARCHIVE"
    else
      awk -F'\t' -v m="$period_id" '$1 ~ m {print > "'"$ARCHIVE"'"; next} {print > "'"$tmp"'"}' "$INBOX"
      mv "$tmp" "$INBOX"
      echo "Archived entries for $period_id -> $ARCHIVE"
    fi
  fi
}

cmd_search() {
  ensure_dirs
  if [[ $# -lt 1 ]]; then echo "search requires a pattern"; exit 1; fi
  local pattern="$*"
  printf "Date\tType\tURL\tTitle\tTags\n"
  grep -i --color=never -e "$pattern" "$INBOX" || true
}

cmd_install_deps() {
  echo "This will try to install: curl lynx xclip"
  if is_cmd dnf; then
    echo "Detected Fedora/RHEL. Using sudo dnf..."
    sudo dnf install -y curl lynx xclip
  elif is_cmd apt; then
    echo "Detected Debian/Ubuntu. Using sudo apt..."
    sudo apt update && sudo apt install -y curl lynx xclip
  else
    echo "Unknown package manager. Please install manually: curl lynx xclip"
  fi
  echo "Optional: fzf for the TUI (sudo dnf install -y fzf)"
}

cmd_export() {
  ensure_dirs
  local period=""
  if [[ $# -ge 1 && "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then period="$1"; else period=""; fi
  echo "["
  local first=1
  while IFS=$'\t' read -r date type url title tags; do
    if [[ -n "$period" && "$date" != "$period"* ]]; then continue; fi
    [[ $first -eq 0 ]] && echo ","
    printf "  {\"date\":\"%s\",\"type\":\"%s\",\"url\":\"%s\",\"title\":%s,\"tags\":%s}" \
      "$date" "$type" "$url" \
      "$(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$tags"  | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')"
    first=0
  done < "$INBOX"
  echo; echo "]"
}

cmd_import() {
  ensure_dirs
  if [[ $# -lt 1 ]]; then echo "import requires a file path"; exit 1; fi
  local file="$1"; shift || true
  local fmt="auto"
  if [[ "${1:-}" == "--format" ]]; then fmt="${2:-auto}"; shift 2; fi
  if [[ "$fmt" == "auto" ]]; then
    if [[ "$file" == *.tsv ]]; then fmt="tsv"; else fmt="csv"; fi
  fi
  local IFS_SAVE="$IFS"; local sep=$'\t'; [[ "$fmt" == "csv" ]] && sep=','
  local today; today="$(date -u +%Y-%m-%d)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ [Uu][Rr][Ll] ]] && [[ ! "$line" =~ ^https?:// ]]; then continue; fi
    IFS="$sep" read -r c1 c2 c3 c4 c5 <<< "$line"; IFS="$IFS_SAVE"
    c1="${c1##[[:space:]]}"; c1="${c1%%[[:space:]]}"
    c2="${c2##[[:space:]]}"; c2="${c2%%[[:space:]]}"
    c3="${c3##[[:space:]]}"; c3="${c3%%[[:space:]]}"
    c4="${c4##[[:space:]]}"; c4="${c4%%[[:space:]]}"
    c5="${c5##[[:space:]]}"; c5="${c5%%[[:space:]]}"
    local date="${c1:-$today}"; local type="${c2:-}"; local url="${c3:-}"; local title="${c4:-}"; local tags="${c5:-}"
    [[ -n "$url" ]] || continue
    [[ -n "$type" ]] || type="$(detect_type "$url")"
    local merged; merged="$(apply_rules "$url" "$type" "$tags")"
    local new_type="${merged%%|*}"; local new_tags="${merged#*|}"
    title="$(sanitize_field "$title")"; new_tags="$(sanitize_field "$new_tags")"
    printf "%s\t%s\t%s\t%s\t%s\n" "$date" "$new_type" "$url" "$title" "$new_tags" >> "$INBOX"
  done < "$file"
  echo "Imported from: $file"
}

cmd_rules() {
  ensure_dirs
  local sub="${1:-}"; shift || true
  case "$sub" in
    list|"")
      if [[ ! -s "$RULES" ]]; then echo "(no rules)"; else cat "$RULES"; fi
      ;;
    add)
      if [[ $# -lt 1 ]]; then echo "Usage: ./curate.sh rules add <domain> [type] [tags...]"; exit 1; fi
      local dom="$1"; shift || true
      local type="${1:-}"; if [[ $# -ge 1 ]]; then shift; fi
      local tags="${*:-}"
      printf "%s\t%s\t%s\n" "$dom" "$type" "$tags" >> "$RULES"
      echo "Rule added: $dom"
      ;;
    test)
      if [[ $# -lt 1 ]]; then echo "Usage: ./curate.sh rules test <url>"; exit 1; fi
      local url="$1"
      local t="$(detect_type "$url")"
      local merged; merged="$(apply_rules "$url" "$t" "")"
      local new_type="${merged%%|*}"; local new_tags="${merged#*|}"
      echo "Domain: $(url_domain "$url")"
      echo "Type (heuristic): $t"
      echo "Type (after rules): $new_type"
      echo "Default tags (from rules): $new_tags"
      ;;
    *)
      echo "Unknown rules subcommand: $sub"; exit 1;;
  esac
}

cmd_tui() {
  ensure_dirs
  if ! is_cmd fzf; then echo "fzf not found. Install it to use the TUI."; exit 1; fi
  local choice
  choice="$(printf "Add from clipboard\nAdd manual URL\nSearch inbox\nDigest (this week)\nDigest (this month)\nDigest & Archive (this week)\nRules list\nRules add\nRules test URL\nQuit\n" | fzf --prompt="penless » " --height=50% --border)"
  case "$choice" in
    "Add from clipboard")
      read -rp "Tags (space-separated, optional): " tags
      if ./curate.sh clip $tags; then echo "OK"; fi
      ;;
    "Add manual URL")
      read -rp "URL: " url
      read -rp "Tags (space-separated, optional): " tags
      ./curate.sh add "$url" $tags
      ;;
    "Search inbox")
      read -rp "Pattern: " pat
      ./curate.sh search "$pat" | less -R
      ;;
    "Digest (this week)")
      ./curate.sh digest --weekly
      ;;
    "Digest (this month)")
      ./curate.sh digest
      ;;
    "Digest & Archive (this week)")
      ./curate.sh digest --weekly --archive
      ;;
    "Rules list")
      ./curate.sh rules list | less
      ;;
    "Rules add")
      read -rp "Domain: " dom
      read -rp "Type (optional): " typ
      read -rp "Tags (space-separated, optional): " tags
      ./curate.sh rules add "$dom" $typ $tags
      ;;
    "Rules test URL")
      read -rp "URL: " u
      ./curate.sh rules test "$u"
      ;;
    *)
      echo "Bye."
      ;;
  esac
}

main() {
  local cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    init) cmd_init "$@";;
    add) cmd_add "$@";;
    clip) cmd_clip "$@";;
    digest) cmd_digest "$@";;
    search) cmd_search "$@";;
    install-deps) cmd_install_deps "$@";;
    export) cmd_export "$@";;
    import) cmd_import "$@";;
    rules) cmd_rules "$@";;    # NOTE: shift before calling (fixed)
    tui) cmd_tui "$@";;
    ""|-h|--help|help) usage;;
    *) echo "Unknown command: $cmd" >&2; usage; exit 1;;
  esac
}

main "$@"
