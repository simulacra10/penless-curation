// curate.cpp — C++ refactor of the curate.sh workflow
// Build: g++ -std=c++20 -O2 -o curate curate.cpp
//
// Runtime files (defaults):
//   $CURATE_HOME (or CWD)
//     ├── inbox.tsv
//     ├── rules.tsv            # regex\tkind (created with sensible defaults on first run)
//     ├── templates/
//     │     └── header.md      # included at top of digests unless --no-header
//     └── digests/             # default output target for `digest`
//
// CLI:
//   curate add <url> [tags...] [--title "..."] [--date YYYY-MM-DD]
//   curate digest [-gt|--group-tags] [--tags-only] [-pd]
//                 [--week YYYY-Www | --start YYYY-MM-DD --end YYYY-MM-DD]
//                 [--no-header] [-o <path>|-]
//   curate clear-inbox [--archive-dir <dir>]
//   curate list [--limit N] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
//   curate help | -h | --help
//
// Notes:
//   • Writes exactly 5 TAB-separated columns on `add`: DATE  KIND  URL  TITLE  TAGS
//   • KIND is detected from URL via rules in rules.tsv (regex → kind).
//   • ISO week math (Mon..Sun) via Jan 4 rule.
//   • -pd makes a small, self-contained HTML (no external deps).
//   • Digest bullet format (no date):
//       - [domain](url) — *kind* — Title — #Tag1 #Tag2
//

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace std;
namespace fs = std::filesystem;

using days = std::chrono::days;
using sys_days = std::chrono::time_point<std::chrono::system_clock, days>;

// --- Portable localtime shim ---
static inline void portable_localtime(const time_t* t, std::tm* out) {
#ifdef _WIN32
    localtime_s(out, t);
#else
    localtime_r(t, out);
#endif
}

// ===== Utilities =====
static inline string toLower(string s){ for(char &c: s) c = (char)tolower((unsigned char)c); return s; }
static inline string trim(const string &s){ size_t a=0,b=s.size(); while(a<b && isspace((unsigned char)s[a])) ++a; while(b>a && isspace((unsigned char)s[b-1])) --b; return s.substr(a,b-a);}

static string getenvOr(const char* k, const string& defv){ const char* v = std::getenv(k); return v? string(v): defv; }

static string todayISO(){
    auto now = std::chrono::floor<days>(std::chrono::system_clock::now());
    std::chrono::year_month_day ymd(now);
    std::ostringstream oss;
    oss << int(ymd.year()) << "-"
        << setw(2) << setfill('0') << unsigned(ymd.month()) << "-"
        << setw(2) << setfill('0') << unsigned(ymd.day());
    return oss.str();
}

static optional<sys_days> parseISODate(const string& s){
    std::regex re("^(\\d{4})-(\\d{2})-(\\d{2})$");
    std::smatch m;
    if(!std::regex_match(s,m,re)) return nullopt;
    int y=stoi(m[1]), mo=stoi(m[2]), d=stoi(m[3]);
    using namespace std::chrono;
    if(mo<1||mo>12||d<1||d>31) return nullopt;
    sys_days z = sys_days{ year{y}/month{static_cast<unsigned>(mo)}/day{static_cast<unsigned>(d)} };
    year_month_day ymd(z);
    if(int(ymd.year())!=y || unsigned(ymd.month())!=unsigned(mo) || unsigned(ymd.day())!=unsigned(d)) return nullopt;
    return z;
}

struct ISOWeek { int year; int week; sys_days monday; sys_days sunday; };

static ISOWeek isoWeekFromDate(sys_days z){
    using namespace std::chrono;
    weekday wd{z}; // Sun=0 ... Sat=6
    int days_since_monday = (wd.c_encoding()==0? 6: int(wd.c_encoding())-1);
    sys_days monday = z - days(days_since_monday);
    sys_days thursday = monday + days(3);
    year_month_day ymd_th(thursday);
    int iso_year = int(ymd_th.year());
    sys_days jan4 = sys_days{year{iso_year}/January/4};
    weekday wd_j4{jan4};
    int j4_dsmon = (wd_j4.c_encoding()==0? 6: int(wd_j4.c_encoding())-1);
    sys_days week1_monday = jan4 - days(j4_dsmon);
    int week_num = 1 + int((monday - week1_monday).count()/7);
    return ISOWeek{iso_year, week_num, monday, monday+days(6)};
}

static optional<pair<int,int>> parseISOWeekStr(const string& s){
    // YYYY-Www
    std::regex re("^(\\d{4})-W(\\d{2})$");
    std::smatch m;
    if(!std::regex_match(s,m,re)) return nullopt;
    int y=stoi(m[1]); int w=stoi(m[2]); if(w<1||w>53) return nullopt; return {{y,w}};
}

static ISOWeek weekBounds(int y, int w){
    using namespace std::chrono;
    sys_days jan4 = sys_days{year{y}/January/4}; weekday wd_j4{jan4};
    int j4_dsmon = (wd_j4.c_encoding()==0? 6: int(wd_j4.c_encoding())-1);
    sys_days week1_monday = jan4 - days(j4_dsmon);
    sys_days monday = week1_monday + days(7*(w-1));
    return ISOWeek{y,w,monday,monday+days(6)};
}

static string fmtDate(sys_days z){
    std::chrono::year_month_day ymd(z);
    std::ostringstream oss;
    oss<< int(ymd.year()) <<"-"<< setw(2) << setfill('0') << unsigned(ymd.month()) <<"-"<< setw(2) << setfill('0') << unsigned(ymd.day());
    return oss.str();
}

static string fmtISOWeek(int y,int w){
    std::ostringstream oss; oss<<y<<"-W"<<setw(2)<<setfill('0')<<w; return oss.str();
}

// ===== Record model =====
struct Rec{
    sys_days date; string kind; string url; string title; string tags; // 5 columns
};

static vector<string> splitTabs(const string& line){
    vector<string> out; string cur;
    for(char c: line){ if(c=='\t'){ out.push_back(cur); cur.clear(); } else cur.push_back(c); }
    out.push_back(cur);
    return out;
}

static string joinTabs(const vector<string>& cols){
    string s;
    for(size_t i=0;i<cols.size();++i){ if(i) s.push_back('\t'); s += cols[i]; }
    return s;
}

static bool fileExists(const fs::path& p){ std::error_code ec; return fs::exists(p,ec); }

// ===== Paths =====
static fs::path curateHome(){ string h = getenvOr("CURATE_HOME", string(".")); return fs::path(h); }
static fs::path inboxPath(){ return curateHome()/ "inbox.tsv"; }
static fs::path templatesDir(){ return curateHome()/ "templates"; }
static fs::path headerPath(){ return templatesDir()/ "header.md"; }
static fs::path digestsDir(){ return curateHome()/ "digests"; }

// ===== rules.tsv support =====
static fs::path rulesPath(){ return curateHome() / "rules.tsv"; }

struct Rule { std::regex re; std::string kind; };

static void ensureDefaultRulesFile(){
    if(fileExists(rulesPath())) return;
    fs::create_directories(curateHome());
    std::ofstream o(rulesPath());
    if(!o) return;

    // Comments
    o << "# Penless Curation kind rules\n";
    o << "# Format: <regex>\\t<kind>\n";
    o << "# Lines beginning with # are comments. Blank lines ignored.\n";
    o << "# Examples below — edit as needed.\n\n";

    // Pattern\tkind  (note: real TABs via \t)
    o << "youtube\\.com/|youtu\\.be/\tvideo\n";
    o << "(?:^|https?://)?(?:www\\.)?(?:twitter\\.com|x\\.com)/\ttweet\n";
    o << "(?:^|https?://)?(?:www\\.)?substack\\.com/\tpost\n";
    o << "(?:^|https?://)?(?:www\\.)?reddit\\.com/\tthread\n";
    o << "(?:^|https?://)?news\\.ycombinator\\.com/\thn\n";
    o << "(?:^|https?://)?(?:www\\.)?github\\.com/\tcode\n";
    o << "\\.pdf(?:$|\\?)\tpdf\n";
}

static std::vector<Rule> loadRules(){
    ensureDefaultRulesFile();
    std::vector<Rule> rules;
    std::ifstream in(rulesPath());
    std::string line;
    while(std::getline(in, line)){
        std::string s = trim(line);
        if(s.empty() || s[0]=='#') continue;
        auto cols = splitTabs(s);
        if(cols.size() < 2) continue;
        try{
            rules.push_back(Rule{
                std::regex(cols[0], std::regex::icase | std::regex::optimize),
                cols[1]
            });
        }catch(const std::regex_error&){
            // Skip invalid patterns instead of failing the whole run
        }
    }
    return rules;
}

// ===== Default path helpers for digests =====
static string safeBaseFromRangeLabel(const string& label){
    string s = label;
    size_t p = 0;
    while((p = s.find(" to ", p)) != string::npos){ s.replace(p, 4, "_to_"); p += 4; }
    for(char& c : s){
        if(!(isalnum((unsigned char)c) || c=='-' || c=='_')) c = '-';
    }
    if(s.empty()) s = "digest";
    return s;
}

static fs::path defaultDigestPath(const string& rangeLabel, bool html){
    return digestsDir() / (safeBaseFromRangeLabel(rangeLabel) + (html? ".html" : ".md"));
}

// ===== Inbox IO =====
static vector<Rec> loadInbox(){
    vector<Rec> v;
    if(!fileExists(inboxPath())) return v;
    ifstream in(inboxPath());
    string line;
    while(getline(in,line)){
        if(trim(line).empty()) continue;
        auto cols = splitTabs(line);
        string sdate = cols.size()>0? cols[0]: todayISO();
        auto dopt = parseISODate(trim(sdate)); if(!dopt) continue; // skip bad row silently
        string kind = cols.size()>1? cols[1]: "link";
        string url  = cols.size()>2? cols[2]: "";
        string title= cols.size()>3? cols[3]: "";
        string tags = cols.size()>4? cols[4]: "";
        v.push_back(Rec{*dopt, kind, url, title, tags});
    }
    return v;
}

static bool appendInbox(const Rec& r){
    fs::create_directories(curateHome());
    ofstream out(inboxPath(), ios::app);
    if(!out) return false;
    vector<string> cols = { fmtDate(r.date), r.kind, r.url, r.title, r.tags };
    out<< joinTabs(cols) <<"\n";
    return true;
}

// ===== Kind detection via rules.tsv =====
static string detectKind(const string& url){
    static const std::vector<Rule> RULES = loadRules(); // loaded once per process
    for(const auto& r : RULES){
        if(std::regex_search(url, r.re)) return r.kind;
    }
    return "article";
}

static string urlDomain(const string& url){
    std::regex re(R"((?:https?://)?([^/]+))", std::regex_constants::icase);
    std::smatch m;
    if(std::regex_search(url,m,re)) return m[1];
    return url;
}

// ===== Tag normalization (display) =====
static bool isAllCapsWord(const string& s){
    bool hasAlpha=false;
    for(char c: s){ if(isalpha((unsigned char)c)){ hasAlpha=true; if(!isupper((unsigned char)c)) return false; } }
    return hasAlpha;
}

static string normalizeTagDisplayOne(string t){
    t = trim(t); if(t.empty()) return t;
    bool hadHash=false; if(t.size()>0 && t[0]=='#'){ hadHash=true; t = t.substr(1); }
    if(isAllCapsWord(t)) return string(hadHash?"#":"") + t;
    if(!t.empty()) t[0] = (char)toupper((unsigned char)t[0]);
    return string(hadHash?"#":"") + t;
}

static vector<string> splitTags(const string& s){
    vector<string> out; string cur; std::istringstream iss(s);
    while(iss>>cur){ out.push_back(cur); }
    return out;
}

static string normalizeTagsForStorage(const vector<string>& raw){
    vector<string> cleaned; cleaned.reserve(raw.size()); set<string> seen;
    for(auto t: raw){
        t=trim(t); if(t.empty()) continue;
        if(t[0] != '#') t = string("#") + t;
        if(!seen.count(t)){ cleaned.push_back(t); seen.insert(t); }
    }
    std::ostringstream oss;
    for(size_t i=0;i<cleaned.size();++i){ if(i) oss<<' '; oss<<cleaned[i]; }
    return oss.str();
}

// ===== Filtering =====
static vector<Rec> filterByDateRange(const vector<Rec>& all, sys_days a, sys_days b){
    vector<Rec> out; for(const auto& r: all){ if(r.date>=a && r.date<=b) out.push_back(r); }
    sort(out.begin(), out.end(), [](const Rec& x, const Rec& y){ return x.date<y.date; });
    return out;
}

// ===== Rendering =====
static string readFileOrEmpty(const fs::path& p){
    if(!fileExists(p)) return "";
    std::ifstream in(p); std::ostringstream ss; ss<< in.rdbuf(); return ss.str();
}

struct RenderOpts{ bool groupTags=false; bool tagsOnly=false; bool includeHeader=true; bool html=false; string headerText; string rangeLabel; };

// New format (no date): - [domain](url) — *kind* — Title — #Tag1 #Tag2
static string recLineMarkdown(const Rec& r){
    string dom  = urlDomain(r.url);
    string kind = r.kind;
    string t    = trim(r.title);
    std::ostringstream oss;
    oss << "- [" << dom << "](" << r.url << ") — *" << kind << "*";
    if(!t.empty()) oss << " — " << t;
    vector<string> tags = splitTags(r.tags);
    if(!tags.empty()){
        oss << " — ";
        for(size_t i=0;i<tags.size(); ++i){
            if(i) oss << ' ';
            oss << normalizeTagDisplayOne(tags[i]); // keeps leading #
        }
    }
    return oss.str();
}

static string renderGroupedByTagsMarkdown(const vector<Rec>& rows){
    map<string, vector<const Rec*>> byTag;
    for(const auto& r: rows){
        for(auto &t: splitTags(r.tags)){
            string disp = normalizeTagDisplayOne(t);
            if(!disp.empty()) byTag[disp].push_back(&r);
        }
    }
    std::ostringstream out; out<<"## By Tag\n\n";
    for(const auto& [tag, list]: byTag){
        out<<"### "<<tag<<"\n";
        for(const auto* pr: list){ out<< recLineMarkdown(*pr) <<"\n"; }
        out<<"\n";
    }
    if(byTag.empty()) out<<"(No tags in range)\n";
    return out.str();
}

static string mdToHtml(const string& md){
    std::istringstream in(md);
    std::ostringstream out;
    out << "<!doctype html><html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Digest</title><style>body{max-width:820px;margin:2rem auto;padding:0 1rem;font:16px/1.5 system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif}code,pre{font:13px ui-monospace,Consolas,Menlo,monospace}h1,h2,h3{line-height:1.2}ul{padding-left:1.2rem}</style><body>";
    string line; bool inList=false;
    auto flushList=[&](){ if(inList){ out<<"</ul>"; inList=false; } };
    auto convert=[&](string x){
        x = std::regex_replace(
                x,
                std::regex(R"(\[([^\]]+)\]\(([^)]+)\))"),
                string(R"(<a href="$2" target="_blank">$1</a>)"));
        x = std::regex_replace(x, std::regex(R"(\*([^*]+)\*)"), string("<em>$1</em>"));
        return x;
    };
    while(getline(in,line)){
        string s = trim(line);
        if(s.rfind("# ",0)==0){ flushList(); out<<"<h1>"<< s.substr(2) <<"</h1>"; continue; }
        if(s.rfind("## ",0)==0){ flushList(); out<<"<h2>"<< s.substr(3) <<"</h2>"; continue; }
        if(s.rfind("### ",0)==0){ flushList(); out<<"<h3>"<< s.substr(4) <<"</h3>"; continue; }
        if(s.rfind("- ",0)==0){
            if(!inList){ out<<"<ul>"; inList=true; }
            string item = convert(s.substr(2));
            out<<"<li>"<< item <<"</li>";
            continue;
        }
        if(s.empty()){ flushList(); out<<"<p></p>"; continue; }
        flushList(); out<<"<p>"<< convert(s) <<"</p>";
    }
    flushList(); out << "</body></html>";
    return out.str();
}

// ===== CLI parsing =====
struct Args{
    string cmd; // add,digest,clear-inbox,list,help
    // add
    string url; vector<string> addTags; string addTitle; optional<string> addDateISO;
    // digest
    bool groupTags=false, tagsOnly=false, pd=false, noHeader=false; optional<pair<int,int>> week; optional<sys_days> start, end; string outPath;
    // clear
    string archiveDir;
    // list
    optional<int> limit; optional<sys_days> since, until;
};

static void printHelp(){
    cerr <<
R"HELP(
curate 

A plain‑text workflow for capturing links to `inbox.tsv`, tagging them, and rolling them into weekly (or custom range) digests.  
No databases, no runtimes — just a tiny C++20 CLI, TSV, and Markdown/HTML.

Copyright (c) 2025 Norman Bauer - MIT License

USAGE:
  curate add <url> [tags...] [--title "..."] [--date YYYY-MM-DD]
  curate digest [-gt|--group-tags] [--tags-only] [-pd]
                [--week YYYY-Www | --start YYYY-MM-DD --end YYYY-MM-DD]
                [--no-header] [-o <path>|-]
  curate clear-inbox [--archive-dir <dir>]
  curate list [--limit N] [--since YYYY-MM-DD] [--until YYYY-MM-DD]
  curate help

ENV:
  CURATE_HOME  Root folder for inbox.tsv, templates/, digests/, rules.tsv (default: .)

NOTES:
  • Exactly 5 TAB-separated columns are written on `add`:
      DATE\tKIND\tURL\tTITLE\tTAGS
  • Kind detection is configured via rules.tsv (regex\tkind).
  • ISO week handling uses Mon..Sun and the Jan 4 rule.
  • -pd emits a self-contained HTML page (lightweight Pandoc-like output).
)HELP";
}

static optional<Args> parseCLI(int argc, char** argv){
    if(argc<2){ printHelp(); return nullopt; }
    Args a; a.cmd = argv[1];
    auto need = [&](int i){ if(i>=argc){ cerr<<"Missing value for "<<argv[i-1]<<"\n"; exit(2);} };

    if(a.cmd=="add"){
        if(argc<3){ cerr<<"add: require <url>\n"; exit(2);} a.url = argv[2];
        for(int i=3;i<argc;++i){
            string t=argv[i];
            if(t=="--title"){ need(++i); a.addTitle = argv[i]; continue; }
            if(t=="--date"){ need(++i); auto p=parseISODate(argv[i]); if(!p){ cerr<<"Invalid --date"<<"\n"; exit(2);} a.addDateISO=fmtDate(*p); continue; }
            a.addTags.push_back(t);
        }
        return a;
    }
    if(a.cmd=="digest"){
        for(int i=2;i<argc;++i){
            string t=argv[i];
            if(t=="-gt"||t=="--group-tags"){ a.groupTags=true; continue; }
            if(t=="--tags-only"){ a.tagsOnly=true; continue; }
            if(t=="-pd"){ a.pd=true; continue; }
            if(t=="--no-header"){ a.noHeader=true; continue; }
            if(t=="--week"){ need(++i); auto w=parseISOWeekStr(argv[i]); if(!w){ cerr<<"Invalid --week (use YYYY-Www)\n"; exit(2);} a.week=w; continue; }
            if(t=="--start"){ need(++i); auto p=parseISODate(argv[i]); if(!p){ cerr<<"Invalid --start"<<"\n"; exit(2);} a.start=*p; continue; }
            if(t=="--end"){ need(++i); auto p=parseISODate(argv[i]); if(!p){ cerr<<"Invalid --end"<<"\n"; exit(2);} a.end=*p; continue; }
            if(t=="-o"){ need(++i); a.outPath=argv[i]; continue; }
            cerr<<"Unknown option: "<<t<<"\n"; exit(2);
        }
        return a;
    }
    if(a.cmd=="clear-inbox"){
        for(int i=2;i<argc;++i){ string t=argv[i]; if(t=="--archive-dir"){ need(++i); a.archiveDir=argv[i]; continue; } cerr<<"Unknown option: "<<t<<"\n"; exit(2); }
        return a;
    }
    if(a.cmd=="list"){
        for(int i=2;i<argc;++i){
            string t=argv[i];
            if(t=="--limit"){ need(++i); a.limit=stoi(argv[i]); continue; }
            if(t=="--since"){ need(++i); auto p=parseISODate(argv[i]); if(!p){ cerr<<"Invalid --since"<<"\n"; exit(2);} a.since=*p; continue; }
            if(t=="--until"){ need(++i); auto p=parseISODate(argv[i]); if(!p){ cerr<<"Invalid --until"<<"\n"; exit(2);} a.until=*p; continue; }
            cerr<<"Unknown option: "<<t<<"\n"; exit(2);
        }
        return a;
    }
    if(a.cmd=="help"||a.cmd=="-h"||a.cmd=="--help"){ printHelp(); exit(0); }
    cerr<<"Unknown command: "<<a.cmd<<"\n"; printHelp(); return nullopt;
}

// ===== Commands =====
static int cmd_add(const Args& a){
    Rec r;
    r.date  = a.addDateISO? *parseISODate(*a.addDateISO) : *parseISODate(todayISO());
    r.url   = a.url;
    r.kind  = detectKind(a.url);
    r.title = a.addTitle;
    r.tags  = normalizeTagsForStorage(a.addTags);
    if(!appendInbox(r)){ cerr<<"Failed to append to "<< inboxPath() <<"\n"; return 1; }
    cout<<"Added: "<< fmtDate(r.date) <<"\t"<< r.kind <<"\t"<< r.url <<"\t"<< r.title <<"\t"<< r.tags <<"\n";
    return 0;
}

static pair<sys_days,sys_days> computeRange(const Args& a, string& labelOut){
    if(a.start && a.end){ labelOut = fmtDate(*a.start) + string(" to ") + fmtDate(*a.end); return {*a.start,*a.end}; }
    if(a.week){ auto wb = weekBounds(a.week->first, a.week->second); labelOut = fmtISOWeek(wb.year, wb.week); return {wb.monday, wb.sunday}; }
    auto now = std::chrono::floor<days>(std::chrono::system_clock::now()); auto w = isoWeekFromDate(now); labelOut = fmtISOWeek(w.year, w.week); return {w.monday, w.sunday};
}

static int cmd_digest(const Args& a){
    auto all = loadInbox(); string label; auto [A,B] = computeRange(a,label); auto rows = filterByDateRange(all,A,B);

    RenderOpts ro; 
    ro.groupTags     = a.groupTags; 
    ro.tagsOnly      = a.tagsOnly; 
    ro.includeHeader = !a.noHeader; 
    ro.html          = a.pd; 
    ro.headerText    = readFileOrEmpty(headerPath()); 
    ro.rangeLabel    = label;

    // Build Markdown
    string md = [&]{
        std::ostringstream out;
        if(ro.includeHeader && !ro.headerText.empty()){
            out<< ro.headerText;
            if(ro.headerText.back()!='\n') out<<'\n';
            out<<'\n';
        }
        if(!ro.tagsOnly){
            out<< "# All Items " << ro.rangeLabel << "\n\n";
            for(const auto& r: rows){ out<< recLineMarkdown(r) <<"\n"; }
            out<< "\n";
        }
        if(ro.groupTags || ro.tagsOnly){ out<< renderGroupedByTagsMarkdown(rows); }
        return out.str();
    }();

    // Output target:
    // - If -o "-" => stdout
    // - If -o not set => digests/<range>.{md,html}
    // - Else => user-specified path
    if(a.outPath == "-"){
        if(a.pd) cout << mdToHtml(md);
        else     cout << md;
        return 0;
    }

    fs::path outPath = a.outPath.empty()
        ? defaultDigestPath(ro.rangeLabel, a.pd)
        : fs::path(a.outPath);

    fs::create_directories(outPath.parent_path());
    ofstream o(outPath);
    if(!o){
        cerr<<"Failed to write "<< outPath <<"\n";
        return 2;
    }

    if(a.pd) o << mdToHtml(md);
    else     o << md;

    return 0;
}

static int cmd_clear_inbox(const Args& a){
    fs::create_directories(curateHome());
    if(!fileExists(inboxPath())){
        ofstream o(inboxPath());
        cout << "Initialized new inbox.tsv" << '\n';
        return 0;
    }
    fs::path arch = a.archiveDir.empty()? (curateHome()/ "archive") : fs::path(a.archiveDir);
    fs::create_directories(arch);

    auto now = std::chrono::system_clock::now();
    time_t t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{}; portable_localtime(&t,&tm);
    char buf[32]; strftime(buf,sizeof(buf),"%Y%m%d-%H%M%S", &tm);
    fs::path dest = arch / (string("inbox-") + buf + ".tsv");

    std::error_code ec;
    fs::rename(inboxPath(), dest, ec);
    if(ec){
        ec.clear();
        fs::copy_file(inboxPath(), dest, fs::copy_options::overwrite_existing, ec);
        if(ec){
            cerr << "Archive failed: " << ec.message() << '\n';
            return 2;
        }
        ofstream o(inboxPath(), ios::trunc);
    } else {
        ofstream o(inboxPath(), ios::trunc);
    }
    cout << "Archived to " << dest << " and cleared inbox.tsv" << '\n';
    return 0;
}

static int cmd_list(const Args& a){
    auto all = loadInbox(); vector<Rec> rows = all;
    if(a.since || a.until){
        sys_days lo = a.since.value_or(sys_days::min());
        sys_days hi = a.until.value_or(sys_days::max());
        rows = filterByDateRange(all, lo, hi);
    }
    if(a.limit && *a.limit < (int)rows.size()) rows.resize(*a.limit);
    for(const auto& r: rows){
        cout<< fmtDate(r.date) <<"\t"<< r.kind <<"\t"<< r.url <<"\t"<< r.title <<"\t"<< r.tags <<"\n";
    }
    return 0;
}

int main(int argc, char** argv){
    auto args = parseCLI(argc, argv);
    if(!args) return 2;
    fs::create_directories(curateHome());
    fs::create_directories(templatesDir());
    fs::create_directories(digestsDir());
    if(!fileExists(inboxPath())){ ofstream o(inboxPath()); } // first-run convenience
    // ensure rules.tsv exists with defaults if missing
    ensureDefaultRulesFile();

    if(args->cmd=="add") return cmd_add(*args);
    if(args->cmd=="digest") return cmd_digest(*args);
    if(args->cmd=="clear-inbox") return cmd_clear_inbox(*args);
    if(args->cmd=="list") return cmd_list(*args);
    printHelp();
    return 2;
}
