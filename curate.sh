#!/usr/bin/env bash
# Penless Curation v4 — curate.sh
# Plain-text curation: TSV in, Markdown out.

set -Eeuo pipefail
IFS=$'\n\t'

# --- Paths / files ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"
INBOX="$ROOT_DIR/inbox.tsv"
ARCHIVE_FLAT="$ROOT_DIR/archive.tsv"
RULES="$ROOT_DIR/rules.tsv"
NOTES_DIR="$ROOT_DIR/notes"
TEMPLATES_DIR="$ROOT_DIR/templates"
MONTHLY_HEADER="$TEMPLATES_DIR/monthly_header.md"
ARCHIVE_DIR="$ROOT_DIR/archive"
HEADER=$'date\ttype\turl\ttitle\ttags'

# --- YouTube parsing / HTTP ---
YTDLP_BIN="${YTDLP_BIN:-yt-dlp}"
USER_AGENT="penless-curation/4"

# --- utils ---
log(){ printf "[curate] %s\n" "$*" >&2; }
die(){ printf "[curate:error] %s\n" "$*" >&2; exit 1; }
require(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
mkdirp(){ mkdir -p "$1"; }

ensure_files(){
  mkdirp "$ROOT_DIR" "$NOTES_DIR" "$TEMPLATES_DIR" "$ARCHIVE_DIR"
  [[ -f "$INBOX" ]] || { printf '%s\n' "$HEADER" >"$INBOX"; }
  [[ -f "$ARCHIVE_FLAT" ]] || { : >"$ARCHIVE_FLAT"; }
  [[ -f "$RULES" ]] || { : >"$RULES"; }
  [[ -f "$MONTHLY_HEADER" ]] || cat >"$MONTHLY_HEADER" <<'EOF'
# 🎙️ Captain Contrary’s Weekly/Monthly Brief

*Generated with Penless Curation — plain text, your brain, no gimmicks.*
EOF
}

usage(){ cat <<'EOF'
Usage: ./curate.sh <command> [args]

Commands:
  init
  add [-t TYPE] URL [tags...]
  clip [tags...]                  (requires xclip)
  search PATTERN
  rules list | add <domain> [type] [tags...] | test <url>
  digest [YYYY-MM] [--archive] [--hugo] [--hugo-section SECTION]
  import FILE.(tsv|csv) [--format tsv|csv|auto]
  export [YYYY-MM]                (JSON to stdout)
  tui                             (requires fzf)
  install-deps
  inbox-archive                   (archive inbox.tsv and reset header)
EOF
}

# --- helpers ---
normalize_ws(){ sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g'; }

html_entities_decode(){
  # Minimal decode for common entities (no external deps)
  sed -E 's/&amp;/\&/g; s/&#38;/\&/g; s/&quot;/"/g; s/&#34;/"/g; s/&#39;/'"'"'/g; s/&apos;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g'
}

url_domain(){
  local url="$1"
  printf '%s\n' "$url" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s/^([^/]+).*/\1/; s/^www[0-9]*\.//'
}

is_youtube_url(){
  local u="${1,,}"
  case "$u" in
    *://youtu.be/*|*://www.youtu.be/*|*://m.youtu.be/*|\
*://youtube.com/watch*|*://www.youtube.com/watch*|*://m.youtube.com/watch*|\
*://youtube.com/shorts/*|*://www.youtube.com/shorts/*|\
*://youtube.com/live/*|*://www.youtube.com/live/*) return 0;;
    *) return 1;;
  esac
}

# --- Title fetchers ---
html_title_via_curl(){
  local url="$1"; local t
  t=$(curl -Lfs --max-time 15 --retry 1 --retry-max-time 20 -A "$USER_AGENT" "$url" 2>/dev/null \
      | tr '\n' ' ' \
      | sed -E 's/.*<title[^>]*>([^<]+)<\/title>.*/\1/I') || true
  t=$(printf '%s' "$t" | normalize_ws | html_entities_decode)
  printf '%s\n' "${t:-Untitled}"
}

html_title_via_lynx(){
  local url="$1"; local t
  t=$(lynx -dump -nolist "$url" 2>/dev/null | sed -n '1p') || true
  t=$(printf '%s' "$t" | normalize_ws)
  printf '%s\n' "${t:-Untitled}"
}

get_title_youtube_via_ytdlp(){
  local url="$1"; local t=""
  if command -v "$YTDLP_BIN" >/dev/null 2>&1; then
    t=$("$YTDLP_BIN" --no-warnings -e -- "$url" 2>/dev/null || true)
    t=$(printf '%s' "$t" | head -n1 | normalize_ws)
  fi
  printf '%s\n' "$t"
}

get_title_youtube_via_meta(){
  local url="$1"; local t=""; local html
  html=$(curl -Lfs --max-time 20 -A "$USER_AGENT" "$url" 2>/dev/null | tr '\n' ' ')
  # Prefer og:title, then name=title, then <title>
  t=$(printf '%s' "$html" \
     | sed -E 's/.*<meta[^>]+property=["'\'']og:title["'\''][^>]+content=["'\'']([^"'\'']+)["'\''][^>]*>.*/\1/I')
  [[ -n "$t" ]] || t=$(printf '%s' "$html" \
     | sed -E 's/.*<meta[^>]+name=["'\'']title["'\''][^>]+content=["'\'']([^"'\'']+)["'\''][^>]*>.*/\1/I')
  [[ -n "$t" ]] || t=$(printf '%s' "$html" \
     | sed -E 's/.*<title[^>]*>([^<]+)<\/title>.*/\1/I')
  t=$(printf '%s' "$t" | normalize_ws | html_entities_decode)
  printf '%s\n' "$t"
}

clean_youtube_title(){
  # Strip trailing " - YouTube" and leading hashtag blocks like "#tag #tag Title"
  sed -E 's/[[:space:]]+-[[:space:]]+You[Tt]ube$//; s/^((#[^[:space:]]+[[:space:]]*)+)//' | normalize_ws
}

get_title(){
  local url="$1"; local t=""
  if is_youtube_url "$url"; then
    t=$(get_title_youtube_via_ytdlp "$url")
    [[ -n "$t" ]] || t=$(get_title_youtube_via_meta "$url")
    t=$(printf '%s' "$t" | clean_youtube_title)
    [[ -n "$t" ]] && { printf '%s\n' "$t"; return; }
  fi
  if command -v lynx >/dev/null 2>&1; then
    t=$(html_title_via_curl "$url"); [[ -n "$t" && "$t" != "Untitled" ]] || t=$(html_title_via_lynx "$url")
  else
    t=$(html_title_via_curl "$url")
  fi
  printf '%s\n' "$t"
}

infer_type(){
  local url="$1"; local d
  d="$(url_domain "$url" | tr 'A-Z' 'a-z')"
  case "$d" in
    *youtube.*|*youtu.be*|*vimeo.*|*rumble.*|*odysee.*) echo video ;;
    *substack.com*|*medium.com*|blog.*|*.blog.*)       echo blog ;;
    *reuters.*|*apnews.*|*bbc.*|*nytimes.*|*wsj.com*|*washingtonpost.*|*guardian.*|*bloomberg.*|*cnbc.*|*foxnews.*|*cnn.*|*aljazeera.*) echo news ;;
    *) echo link ;;
  esac
}

apply_rules(){
  local url="$1"; local d="$(url_domain "$url" | tr 'A-Z' 'a-z')"
  local best_dom="" best_type="" best_tags=""
  while IFS=$'\t' read -r rdom rtype rtags || [[ -n "${rdom-}" ]]; do
    [[ -n "${rdom-}" ]] || continue
    [[ "$rdom" =~ ^# ]] && continue
    local rlow="$(printf '%s' "$rdom" | tr 'A-Z' 'a-z')"
    if [[ "$d" == "$rlow" || "$d" == *".$rlow" ]]; then
      (( ${#rlow} > ${#best_dom} )) && { best_dom="$rlow"; best_type="${rtype-}"; best_tags="${rtags-}"; }
    fi
  done < "$RULES"
  printf '%s\t%s\n' "${best_type}" "${best_tags}"
}

month_from(){
  local in="${1:-}"
  if [[ -z "$in" ]]; then date -u +%Y-%m; return; fi
  if [[ "$in" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then printf '%s\n' "$in"; return; fi
  if [[ "$in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then printf '%.7s\n' "$in"; return; fi
  die "Invalid month: '$in' (expected YYYY-MM)"
}

# --- commands ---
cmd_init(){ ensure_files; log "Initialized in $ROOT_DIR"; }

cmd_add(){
  ensure_files
  local type_override="" url=""; local -a tags=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--type) shift; type_override="${1:-}" || true ;;
      http*|www.*) url="$1" ;;
      *) tags+=("$1") ;;
    esac; shift || true
  done
  [[ -n "$url" ]] || die "add: URL required"
  [[ "$url" =~ ^http ]] || url="https://$url"

  local title; title="$(get_title "$url")"
  local t="${type_override:-$(infer_type "$url")}"
  local rule_type rule_tags
  IFS=$'\t' read -r rule_type rule_tags < <(apply_rules "$url") || true
  [[ -n "${rule_type}" ]] && t="$rule_type"
  local all_tags; all_tags="$(printf '%s %s' "${tags[*]-}" "${rule_tags-}" | normalize_ws)"

  local today; today=$(date -u +%Y-%m-%d)
  printf '%s\t%s\t%s\t%s\t%s\n' "$today" "$t" "$url" "$title" "$all_tags" >> "$INBOX"
  log "Added: [$t] $title"
}

cmd_clip(){
  ensure_files; require xclip
  local url; url="$(xclip -o -selection clipboard | head -n1 | tr -d '\r' | tr -d '\n')"
  [[ -n "$url" ]] || die "Clipboard empty"
  cmd_add "$url" "$@"
}

cmd_search(){ ensure_files; [[ $# -ge 1 ]] || die "search: PATTERN required"; grep -i -- "$1" "$INBOX" || true; }

cmd_rules(){
  ensure_files
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list) cat "$RULES" ;;
    add)
      local dom="${1:-}"; shift || true; [[ -n "$dom" ]] || die "rules add: domain required"
      local rtype="${1:-}"; shift || true
      local rtags="${*:-}"
      printf '%s\t%s\t%s\n' "$dom" "$rtype" "$rtags" >> "$RULES"
      log "Rule added for $dom"
      ;;
    test)
      local url="${1:-}"; [[ -n "$url" ]] || die "rules test: URL required"
      local t="$(infer_type "$url")"; local rtype rtags
      IFS=$'\t' read -r rtype rtags < <(apply_rules "$url") || true
      [[ -n "$rtype" ]] && t="$rtype"
      log "domain=$(url_domain "$url") type=$t tags='$rtags'"
      ;;
    *) die "Unknown rules subcommand: $sub" ;;
  esac
}

build_md_line(){ awk -F '\t' '{printf("- %s — [%s](%s) — *%s* [%s]\n", $1, $4, $3, $2, $5)}'; }

cmd_digest(){
  ensure_files
  local month="$(month_from "${1:-}")"; [[ "${1-}" =~ ^[0-9]{4}-[0-9]{2}$ ]] && shift || true
  local do_archive=false do_hugo=false hugo_section="posts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) do_archive=true ;;
      --hugo) do_hugo=true ;;
      --hugo-section) shift; hugo_section="${1:-posts}" ;;
      *) die "digest: unknown option '$1'" ;;
    esac; shift || true
  done

  mkdirp "$NOTES_DIR"
  local all_md="$NOTES_DIR/all-$month.md"
  local news_md="$NOTES_DIR/news-$month.md"
  local blogs_md="$NOTES_DIR/blogs-$month.md"
  local videos_md="$NOTES_DIR/videos-$month.md"
  local links_md="$NOTES_DIR/links-$month.md"

  for f in "$all_md" "$news_md" "$blogs_md" "$videos_md" "$links_md"; do
    : > "$f"
    [[ -f "$MONTHLY_HEADER" ]] && cat "$MONTHLY_HEADER" >> "$f"
    printf '\n# All Items %s\n\n' "$month" >> "$f"
  done

  awk -F '\t' -v m="$month" 'NR==1{next} $1 ~ "^"m {print}' "$INBOX" \
  | while IFS=$'\t' read -r d t url title tags; do
      line=$(printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$t" "$url" "$title" "$tags" | build_md_line)
      printf '%s\n' "$line" >> "$all_md"
      case "$t" in
        news)  printf '%s\n' "$line" >> "$news_md" ;;
        blog)  printf '%s\n' "$line" >> "$blogs_md" ;;
        video) printf '%s\n' "$line" >> "$videos_md" ;;
        link|*)printf '%s\n' "$line" >> "$links_md" ;;
      esac
    done

  if $do_hugo; then
    # Prepend simple YAML front matter to all_md
    local title="Captain Contrary — $month Digest"
    local tmp=$(mktemp)
    {
      printf '---\n'
      printf 'title: "%s"\n' "$title"
      printf 'date: %s-01\n' "$month"
      printf 'draft: false\n'
      printf 'type: %s\n' "$hugo_section"
      printf 'tags: []\n'
      printf '---\n\n'
      cat "$all_md"
    } > "$tmp" && mv "$tmp" "$all_md"
  fi

  if $do_archive; then
    awk -F '\t' -v m="$month" 'NR==1{next} $1 ~ "^"m {print}' "$INBOX" >> "$ARCHIVE_FLAT"
    awk -F '\t' -v m="$month" 'NR==1{print;next} $1 !~ "^"m {print}' "$INBOX" > "$INBOX.tmp" && mv "$INBOX.tmp" "$INBOX"
  fi

  log "Digest written: $all_md"
}

cmd_import(){
  ensure_files
  local file="${1:-}"; [[ -n "$file" ]] || die "import: file required"
  local fmt="auto"; shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) shift; fmt="${1:-auto}" ;;
      *) die "import: unknown option '$1'" ;;
    esac; shift || true
  done
  [[ -f "$file" ]] || die "import: '$file' not found"
  local ext="${file##*.}"; [[ "$fmt" == auto ]] && fmt="$ext"

  if [[ "$fmt" == tsv ]]; then
    awk -F '\t' 'NR==1&&$1~/(date|\d{4}-\d{2}-\d{2})/{hdr=1} {print}' "$file" | tail -n +1 >> "$INBOX"
  elif [[ "$fmt" == csv ]]; then
    python3 - "$file" <<'PY'
import csv,sys
from datetime import datetime
path=sys.argv[1]
with open(path, newline='') as f:
    r=csv.reader(f)
    for row in r:
        if not row: continue
        if row[0].lower().startswith(('date','yyyy')): continue
        row=row+['']*(5-len(row))
        d,t,u,title,tags=row[:5]
        if not d:
            d=datetime.utcnow().strftime('%Y-%m-%d')
        print('\t'.join([d,t,u,title,tags]))
PY
  else
    die "import: unknown format '$fmt'"
  fi
  log "Imported from $file"
}

cmd_export(){
  ensure_files
  local month="${1:-}"
  [[ -z "$month" ]] || month="$(month_from "$month")"
  awk -F '\t' -v m="$month" 'NR==1{next} m==""|| index($1,m)==1 {print}' "$INBOX" \
  | awk -F '\t' 'BEGIN{print "["} {gsub(/"/,"\\\"",$4); printf("%s{\"date\":\"%s\",\"type\":\"%s\",\"url\":\"%s\",\"title\":\"%s\",\"tags\":\"%s\"}", NR>1?",":"", $1,$2,$3,$4,$5)} END{print "]"}'
}

cmd_tui(){
  ensure_files; require fzf
  local choice
  choice=$(printf '%s\n' \
    "Add URL" "Clipboard Add" "Search" "Digest (this month)" \
    "Rules: list" "Rules: add" "Inbox: archive & reset" \
  | fzf --prompt="curate> " --height=12 --border) || exit 0

  case "$choice" in
    "Add URL") read -rp "URL: " u; read -rp "Tags: " tg; ./curate.sh add "$u" $tg ;;
    "Clipboard Add") read -rp "Tags: " tg; ./curate.sh clip $tg ;;
    "Search") read -rp "Pattern: " p; ./curate.sh search "$p" ;;
    "Digest (this month)") ./curate.sh digest --archive ;;
    "Rules: list") ./curate.sh rules list ;;
    "Rules: add") read -rp "Domain: " d; read -rp "Type (optional): " ty; read -rp "Tags: " tg; ./curate.sh rules add "$d" "$ty" $tg ;;
    "Inbox: archive & reset") ./curate.sh inbox-archive ;;
  esac
}

cmd_install_deps(){
  cat <<'EOS'
Fedora/RHEL:
  sudo dnf install -y bash coreutils gawk grep sed python3 curl lynx xclip fzf pandoc wkhtmltopdf git yt-dlp

Debian/Ubuntu:
  sudo apt install -y bash coreutils gawk grep sed python3 curl lynx xclip fzf pandoc wkhtmltopdf git yt-dlp
EOS
}

cmd_inbox_archive(){
  ensure_files
  mkdirp "$ARCHIVE_DIR"
  local ts; ts=$(date -u +%Y-%m-%dT%H%M%SZ)
  local out="$ARCHIVE_DIR/inbox-$ts.tsv"
  cp -v -- "$INBOX" "$out"
  printf '%s\n' "$HEADER" > "$INBOX.tmp" && mv "$INBOX.tmp" "$INBOX"
  log "Archived inbox -> $out and reset header"
}

# --- dispatch ---
main(){
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init)            cmd_init "$@" ;;
    add)             cmd_add "$@" ;;
    clip)            cmd_clip "$@" ;;
    search)          cmd_search "$@" ;;
    rules)           cmd_rules "$@" ;;
    digest)          cmd_digest "$@" ;;
    import)          cmd_import "$@" ;;
    export)          cmd_export "$@" ;;
    tui)             cmd_tui "$@" ;;
    install-deps)    cmd_install_deps "$@" ;;
    inbox-archive)   cmd_inbox_archive "$@" ;;
    -h|--help|help|'') usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}
main "$@"
