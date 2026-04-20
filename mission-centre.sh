#!/usr/bin/env bash
# Mission Centre - AI Project Launcher (macOS port)
# Requires: bash 3.2+ or zsh, python3 or jq, jig (optional), claude CLI
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/projects.json"
APP_CONFIG_PATH="$SCRIPT_DIR/config.json"
MAX_DEPTH=4
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# ---------------------------------------------------------------------------
# Colors & pre-computed UI strings
# ---------------------------------------------------------------------------
c_reset='\033[0m'
c_cyan='\033[36m'
c_yellow='\033[33m'
c_green='\033[32m'
c_magenta='\033[35m'
c_white='\033[97m'
c_dark_gray='\033[90m'
c_dark_cyan='\033[96m'
c_red='\033[31m'

# Pre-computed so write_banner/write_divider spawn no subshells at render time
_BANNER_H="$(printf '═%.0s' {1..44})"
_DIV_H="$(printf '─%.0s' {1..46})"

cecho()  { local color="$1"; shift; printf "${color}%s${c_reset}\n" "$*"; }
cnecho() { local color="$1"; shift; printf "${color}%s${c_reset}" "$*"; }

# ---------------------------------------------------------------------------
# JSON helpers — jq preferred, python3 fallback
# ---------------------------------------------------------------------------
_json_tool=""

_detect_json_tool() {
    if command -v jq &>/dev/null; then _json_tool="jq"
    elif command -v python3 &>/dev/null; then _json_tool="python3"
    else
        echo "ERROR: jq or python3 is required for JSON parsing." >&2
        exit 1
    fi
}

json_get_field() {
    local file="$1" field="$2"
    if [[ "$_json_tool" == "jq" ]]; then
        jq -r ".$field // empty" "$file" 2>/dev/null
    else
        python3 -c "
import json,sys
try:
    d=json.load(open('$file'))
    v=d.get('$field','')
    print(v if v else '',end='')
except: pass
" 2>/dev/null
    fi
}

json_array_lines() {
    local file="$1"
    if [[ "$_json_tool" == "jq" ]]; then
        jq -c '.[]' "$file" 2>/dev/null
    else
        python3 -c "
import json,sys
try:
    arr=json.load(open('$file'))
    if not isinstance(arr,list): arr=[arr]
    for x in arr: print(json.dumps(x))
except: pass
" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# App config (config.json)
# ---------------------------------------------------------------------------
SCAN_ROOT=""

load_app_config() {
    if [[ -f "$APP_CONFIG_PATH" ]]; then
        local root
        root="$(json_get_field "$APP_CONFIG_PATH" "scanRoot")"
        if [[ -n "$root" ]]; then SCAN_ROOT="$root"; return 0; fi
    fi

    echo ""
    cecho "$c_cyan"      "  Welcome to Mission Centre!"
    cecho "$c_dark_gray" "  Enter the root folder to scan for AI projects."
    cecho "$c_dark_gray" "  Example: /Users/you/AI  or  ~/Dev/Projects"
    echo ""
    printf "  Scan root: "
    read -r root
    [[ -z "$root" ]] && root="$SCRIPT_DIR"
    root="${root/#\~/$HOME}"

    printf '{"scanRoot":"%s"}\n' "$root" > "$APP_CONFIG_PATH"
    SCAN_ROOT="$root"
    cecho "$c_green" "  Config saved to config.json"
    echo ""
}

# ---------------------------------------------------------------------------
# Project discovery
# ---------------------------------------------------------------------------
SKIP_DIRS=( node_modules .git dist build bin obj out .next .nuxt venv .venv __pycache__ .cache Archive Models Resources resources "Design Inspiration" "Company Registration" Finance Investors Exit )
DEFINITIVE_MARKERS=( .git package.json requirements.txt Cargo.toml go.mod pom.xml pyproject.toml )
SUGGESTIVE_MARKERS=( CLAUDE.md README.md README app.js main.py index.js main.ts index.ts )

should_skip_dir() {
    local name="$1" d
    for d in "${SKIP_DIRS[@]}"; do [[ "$name" == "$d" ]] && return 0; done
    return 1
}

dir_has_jig_file() { ls "$1/"*.jig &>/dev/null 2>&1; }

dir_has_definitive_marker() {
    local dir="$1" m
    for m in "${DEFINITIVE_MARKERS[@]}"; do [[ -e "$dir/$m" ]] && return 0; done
    dir_has_jig_file "$dir"
}

dir_has_suggestive_marker() {
    local dir="$1" m
    for m in "${SUGGESTIVE_MARKERS[@]}"; do [[ -e "$dir/$m" ]] && return 0; done
    dir_has_jig_file "$dir"
}

dir_has_any_marker() {
    dir_has_definitive_marker "$1" && return 0
    dir_has_suggestive_marker "$1" && return 0
    return 1
}

any_child_has_markers() {
    local dir="$1" child name
    for child in "$dir"/*/; do
        [[ -d "$child" ]] || continue
        name="${child%/}"; name="${name##*/}"
        should_skip_dir "$name" && continue
        dir_has_any_marker "$child" && return 0
    done
    return 1
}

find_project_dirs() {
    local path="$1" depth="$2"
    (( depth > MAX_DEPTH )) && return
    [[ -d "$path" ]] || return

    local leaf="${path##*/}"
    should_skip_dir "$leaf" && return
    [[ "$path" == "$SCRIPT_DIR" ]] && return

    if dir_has_definitive_marker "$path"; then
        echo "$path"; return
    fi

    if dir_has_suggestive_marker "$path"; then
        if any_child_has_markers "$path"; then
            : # container — recurse into children
        else
            echo "$path"; return
        fi
    fi

    local child
    for child in "$path"/*/; do
        [[ -d "$child" ]] || continue
        find_project_dirs "${child%/}" $(( depth + 1 ))
    done
}

# ---------------------------------------------------------------------------
# Projects config (projects.json)
# ---------------------------------------------------------------------------
PROJ_PATHS=()
PROJ_NAMES=()
PROJ_DESCS=()
PROJ_PROFILES=()
_MENU_RESULT=""

load_config() {
    PROJ_PATHS=(); PROJ_NAMES=(); PROJ_DESCS=(); PROJ_PROFILES=()
    [[ -f "$CONFIG_PATH" ]] || return 0

    local line fields path name desc profile
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Parse all 4 fields in a single subprocess call
        if [[ "$_json_tool" == "jq" ]]; then
            fields="$(printf '%s' "$line" | jq -r '[.path // empty, .name // empty, .description // empty, .profile // "standard"] | @tsv')"
        else
            fields="$(printf '%s' "$line" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print('\t'.join([d.get('path',''), d.get('name',''), d.get('description',''), d.get('profile','standard')]))")"
        fi
        IFS=$'\t' read -r path name desc profile <<< "$fields"
        [[ -z "$path" ]] && continue
        PROJ_PATHS+=("$path")
        PROJ_NAMES+=("$name")
        PROJ_DESCS+=("$desc")
        PROJ_PROFILES+=("$profile")
    done < <(json_array_lines "$CONFIG_PATH")
}

save_config() {
    local i count=${#PROJ_PATHS[@]}
    local today; today="$(date +%Y-%m-%d)"
    local out="["
    for (( i=0; i<count; i++ )); do
        [[ $i -gt 0 ]] && out+=","
        if [[ "$_json_tool" == "jq" ]]; then
            out+="$(jq -n \
                --arg path    "${PROJ_PATHS[$i]}" \
                --arg name    "${PROJ_NAMES[$i]}" \
                --arg desc    "${PROJ_DESCS[$i]}" \
                --arg prof    "${PROJ_PROFILES[$i]}" \
                --arg added   "$today" \
                '{path:$path,name:$name,description:$desc,added:$added,profile:$prof}')"
        else
            # Pass values via environment to avoid any quoting/injection issues
            out+="$(MC_PATH="${PROJ_PATHS[$i]}" MC_NAME="${PROJ_NAMES[$i]}" MC_DESC="${PROJ_DESCS[$i]}" MC_PROF="${PROJ_PROFILES[$i]}" MC_DATE="$today" \
                python3 -c "
import json,os
print(json.dumps({'path':os.environ['MC_PATH'],'name':os.environ['MC_NAME'],'description':os.environ['MC_DESC'],'added':os.environ['MC_DATE'],'profile':os.environ['MC_PROF']}),end='')")"
        fi
    done
    out+="]"
    printf '%s\n' "$out" > "$CONFIG_PATH"
}

config_has_path() {
    local target="$1" p
    for p in "${PROJ_PATHS[@]+"${PROJ_PATHS[@]}"}"; do
        [[ "$p" == "$target" ]] && return 0
    done
    return 1
}

sync_new_projects() {
    cecho "$c_dark_gray" "Scanning $SCAN_ROOT for projects ..."

    # Remove entries whose folders no longer exist
    local i pruned=0
    local keep_paths=() keep_names=() keep_descs=() keep_profiles=()
    for (( i=0; i<${#PROJ_PATHS[@]}; i++ )); do
        if [[ -d "${PROJ_PATHS[$i]}" ]]; then
            keep_paths+=("${PROJ_PATHS[$i]}")
            keep_names+=("${PROJ_NAMES[$i]}")
            keep_descs+=("${PROJ_DESCS[$i]}")
            keep_profiles+=("${PROJ_PROFILES[$i]}")
        else
            cecho "$c_red" "  Removed (folder gone): ${PROJ_NAMES[$i]} (${PROJ_PATHS[$i]})"
            (( pruned++ )) || true
        fi
    done
    if (( pruned > 0 )); then
        PROJ_PATHS=("${keep_paths[@]+"${keep_paths[@]}"}")
        PROJ_NAMES=("${keep_names[@]+"${keep_names[@]}"}")
        PROJ_DESCS=("${keep_descs[@]+"${keep_descs[@]}"}")
        PROJ_PROFILES=("${keep_profiles[@]+"${keep_profiles[@]}"}")
        save_config
        cecho "$c_yellow" "  Removed $pruned stale project(s) from registry."
    fi

    local discovered=()
    while IFS= read -r p; do discovered+=("$p"); done < <(find_project_dirs "$SCAN_ROOT" 0)

    local new_paths=()
    local p
    for p in "${discovered[@]+"${discovered[@]}"}"; do
        config_has_path "$p" || new_paths+=("$p")
    done

    if [[ ${#new_paths[@]} -eq 0 ]]; then
        (( pruned == 0 )) && cecho "$c_dark_gray" "No new projects found."
        return
    fi

    echo ""
    cecho "$c_yellow" "Found ${#new_paths[@]} new project(s) not yet in config."
    write_divider

    local available_profiles; available_profiles="$(list_jig_profiles)"
    local name desc prof
    for p in "${new_paths[@]}"; do
        local default_name="${p##*/}"
        echo ""
        cnecho "$c_cyan" "  New project: "; echo "$p"
        printf "  Name        [%s]: " "$default_name"; read -r name || true
        [[ -z "$name" ]] && name="$default_name"
        printf "  Description (one line, or Enter to skip): "; read -r desc || true
        [[ -z "$desc" ]] && desc="- no description yet -"
        printf "  Profiles: ${c_dark_cyan}%s${c_reset}\n" "$available_profiles"
        printf "  Profile     [standard]: "; read -r prof || true
        [[ -z "$prof" ]] && prof="standard"

        PROJ_PATHS+=("$p")
        PROJ_NAMES+=("$name")
        PROJ_DESCS+=("$desc")
        PROJ_PROFILES+=("$prof")
    done

    save_config
    echo ""
    cecho "$c_green" "  Config saved."
}

# ---------------------------------------------------------------------------
# Session discovery
# ---------------------------------------------------------------------------

# Claude encodes paths: /Users/fred/AI/Foo Bar → -Users-fred-AI-Foo-Bar
encode_path() { printf '%s' "$1" | sed 's|[/ ]|-|g'; }

# Outputs sessions as tab-separated lines: sessionId\tfileMtime\tlabel
get_recent_sessions() {
    local project_path="$1" max_count="${2:-5}"
    local folder_name; folder_name="$(encode_path "$project_path")"
    local folder_path="$CLAUDE_PROJECTS_DIR/$folder_name"
    local index_path="$folder_path/sessions-index.json"

    if [[ -f "$index_path" ]]; then
        python3 - "$index_path" "$folder_path" "$max_count" <<'PYEOF'
import json, sys, os

index_path, folder_path, max_count = sys.argv[1], sys.argv[2], int(sys.argv[3])

def get_label(folder, sid):
    p = os.path.join(folder, sid + '.jsonl')
    if not os.path.exists(p):
        return None
    custom_title = None
    first_prompt = None
    try:
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                if i >= 150: break
                line = line.strip()
                if not line: continue
                try:
                    msg = json.loads(line)
                except: continue
                if not custom_title and msg.get('type') == 'custom-title' and msg.get('customTitle'):
                    custom_title = msg['customTitle'].replace('-', ' ')
                if not first_prompt:
                    if msg.get('type') in ('user', 'human') and isinstance(msg.get('message'), dict):
                        c = msg['message'].get('content', '')
                        if isinstance(c, list):
                            for b in c:
                                if isinstance(b, dict) and b.get('type') == 'text' and b.get('text'):
                                    first_prompt = str(b['text']); break
                        elif c:
                            first_prompt = str(c)
                    if not first_prompt and msg.get('role') == 'user' and msg.get('content'):
                        c = msg['content']
                        if isinstance(c, list):
                            for b in c:
                                if isinstance(b, dict) and b.get('type') == 'text' and b.get('text'):
                                    first_prompt = str(b['text']); break
                        elif isinstance(c, str):
                            first_prompt = c
                if custom_title and first_prompt: break
    except: pass
    return custom_title if custom_title else first_prompt

try:
    data = json.load(open(index_path))
    entries = data.get('entries', [])
    if not entries:
        sys.exit(0)
    entries.sort(key=lambda e: int(e.get('fileMtime', 0)), reverse=True)
    for e in entries[:max_count]:
        sid = e.get('sessionId') or e.get('id', '')
        if not sid: continue
        mtime = int(e.get('fileMtime', 0))
        summary = e.get('summary', '') or ''
        label = summary if summary else (get_label(folder_path, sid) or '(no prompt captured)')
        label = label.replace('\t', ' ').replace('\n', ' ')[:200]
        print(f'{sid}\t{mtime}\t{label}')
except Exception:
    pass
PYEOF
        return
    fi

    [[ -d "$folder_path" ]] || return
    python3 - "$folder_path" "$max_count" <<'PYEOF'
import json, sys, os, glob

folder_path, max_count = sys.argv[1], int(sys.argv[2])
files = sorted(glob.glob(os.path.join(folder_path, '*.jsonl')),
               key=os.path.getmtime, reverse=True)[:max_count]

def get_label(p):
    custom_title = None
    first_prompt = None
    try:
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                if i >= 150: break
                line = line.strip()
                if not line: continue
                try: msg = json.loads(line)
                except: continue
                if not custom_title and msg.get('type') == 'custom-title' and msg.get('customTitle'):
                    custom_title = msg['customTitle'].replace('-', ' ')
                if not first_prompt:
                    if msg.get('type') in ('user','human') and isinstance(msg.get('message'),dict):
                        c = msg['message'].get('content','')
                        if isinstance(c,list):
                            for b in c:
                                if isinstance(b,dict) and b.get('type')=='text' and b.get('text'):
                                    first_prompt=str(b['text']); break
                        elif c: first_prompt=str(c)
                    if not first_prompt and msg.get('role')=='user' and msg.get('content'):
                        c=msg['content']
                        if isinstance(c,list):
                            for b in c:
                                if isinstance(b,dict) and b.get('type')=='text' and b.get('text'):
                                    first_prompt=str(b['text']); break
                        elif isinstance(c,str): first_prompt=c
                if custom_title and first_prompt: break
    except: pass
    return custom_title if custom_title else first_prompt

for p in files:
    sid = os.path.splitext(os.path.basename(p))[0]
    mtime = int(os.path.getmtime(p) * 1000)
    label = get_label(p) or '(no prompt captured)'
    label = label.replace('\t',' ').replace('\n',' ')[:200]
    print(f'{sid}\t{mtime}\t{label}')
PYEOF
}

format_age() {
    local mtime_ms="$1"
    (( mtime_ms <= 0 )) && { printf '?'; return; }

    local now_s mtime_s diff_s
    now_s="$(date +%s)"
    mtime_s=$(( mtime_ms / 1000 ))
    diff_s=$(( now_s - mtime_s ))

    if   (( diff_s <  3600  )); then printf '%dm ago' $(( diff_s / 60 ))
    elif (( diff_s <  86400 )); then printf '%dh ago' $(( diff_s / 3600 ))
    elif (( diff_s < 2592000 )); then printf '%dd ago' $(( diff_s / 86400 ))
    else date -r "$mtime_s" +%Y-%m-%d
    fi
}

truncate_str() {
    local s="$1" max="${2:-55}"
    if (( ${#s} > max )); then printf '%s...' "${s:0:$((max-3))}"
    else printf '%s' "$s"
    fi
}

# ---------------------------------------------------------------------------
# Banner & UI
# ---------------------------------------------------------------------------
write_banner() {
    local title="  MISSION CENTRE  "
    local pad_total=$(( 44 - ${#title} ))
    local pad_l=$(( pad_total / 2 ))
    local pad_r=$(( pad_total - pad_l ))
    printf "${c_cyan}╔%s╗${c_reset}\n" "$_BANNER_H"
    printf "${c_cyan}║%*s%s%*s║${c_reset}\n" $pad_l "" "$title" $pad_r ""
    printf "${c_cyan}╚%s╝${c_reset}\n" "$_BANNER_H"
    echo ""
}

write_divider() {
    printf "${c_dark_gray}%s${c_reset}\n" "$_DIV_H"
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
show_project_menu() {
    write_banner

    local i
    for (( i=0; i<${#PROJ_PATHS[@]}; i++ )); do
        local num=" [$((i+1))]"
        local profile="${PROJ_PROFILES[$i]:-standard}"
        printf "${c_yellow}%-6s${c_reset}" "$num"
        printf "${c_white}%s${c_reset}" "${PROJ_NAMES[$i]}"
        printf "${c_dark_cyan} [%s]${c_reset}\n" "$profile"
        printf "      ${c_dark_gray}%s${c_reset}\n\n" "${PROJ_DESCS[$i]}"
    done

    write_divider
    echo ""

    local meta_sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && meta_sessions+=("$line")
    done < <(get_recent_sessions "$SCAN_ROOT" 5)

    if [[ ${#meta_sessions[@]} -gt 0 ]]; then
        cecho "$c_dark_cyan" "  Recent meta missions:"
        local mi
        for (( mi=0; mi<${#meta_sessions[@]}; mi++ )); do
            IFS=$'\t' read -r sid mtime label <<< "${meta_sessions[$mi]}"
            local age; age="$(format_age "$mtime")"
            local summary; summary="$(truncate_str "$label" 55)"
            printf "   ${c_magenta}[M%d]${c_reset} ${c_white}%s${c_reset}  ${c_dark_gray}(%s)${c_reset}\n" \
                $(( mi+1 )) "$summary" "$age"
        done
        echo ""
    fi

    printf "  ${c_magenta}[M]${c_reset}   New Meta Mission - cross-project planning from %s\n" "$SCAN_ROOT"
    [[ ${#meta_sessions[@]} -gt 0 ]] && \
        printf "  ${c_magenta}[M#]${c_reset}  Resume a meta mission listed above\n"
    echo ""
    printf "  Pick a project number, [M] Meta Mission, [S] Scan, or [Q] Quit: "
    read -r choice || true
    _MENU_RESULT="${choice:-}"
}

show_launch_menu() {
    local idx="$1"
    local path="${PROJ_PATHS[$idx]}"
    local name="${PROJ_NAMES[$idx]}"
    local profile="${PROJ_PROFILES[$idx]:-standard}"

    echo ""
    printf "  ${c_dark_gray}Project : ${c_reset}${c_cyan}%s${c_reset}  ${c_dark_cyan}[%s]${c_reset}\n" "$name" "$profile"
    printf "  ${c_dark_gray}Path    : %s${c_reset}\n" "$path"
    printf "  ${c_dark_gray}CLAUDE.md: ${c_reset}%b\n\n" "$(claudemd_status "$path")"

    local sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && sessions+=("$line")
    done < <(get_recent_sessions "$path" 5)

    if [[ ${#sessions[@]} -gt 0 ]]; then
        cecho "$c_dark_cyan" "  Recent missions:"
        local si
        for (( si=0; si<${#sessions[@]}; si++ )); do
            IFS=$'\t' read -r sid mtime label <<< "${sessions[$si]}"
            local age; age="$(format_age "$mtime")"
            local summary; summary="$(truncate_str "$label" 55)"
            printf "   ${c_green}[R%d]${c_reset} ${c_white}%s${c_reset}  ${c_dark_gray}(%s)${c_reset}\n" \
                $(( si+1 )) "$summary" "$age"
        done
        echo ""
    fi

    local profile_desc=""
    local pf="$SCRIPT_DIR/profiles/${profile}.json"
    [[ -f "$pf" ]] && profile_desc="$(jq -r '.description // empty' "$pf" 2>/dev/null)"

    if command -v jig &>/dev/null; then
        printf "  ${c_green}[L]${c_reset}  Launch                - jig run %s (project default)\n" "$profile"
        printf "  ${c_yellow}[J]${c_reset}  Launch with Jig       - pick a different profile\n"
    elif [[ -n "$profile_desc" ]]; then
        printf "  ${c_green}[L]${c_reset}  Launch [%s]           - %s\n" "$profile" "$profile_desc"
    else
        printf "  ${c_green}[L]${c_reset}  Launch                - open claude in project folder\n"
    fi
    [[ ${#sessions[@]} -gt 0 ]] && \
        printf "  ${c_green}[R#]${c_reset} Resume mission        - resume a session listed above\n"
    printf "  ${c_yellow}[N]${c_reset}  Rename project        - currently \"%s\"\n" "$name"
    printf "  ${c_yellow}[P]${c_reset}  Change profile        - currently [%s]\n" "$profile"
    if [[ ! -f "$path/CLAUDE.md" ]]; then
        printf "  ${c_yellow}[I]${c_reset}  Init CLAUDE.md        - generate starter file with /init\n"
    else
        printf "  ${c_dark_gray}[I]${c_reset}  Reinit CLAUDE.md      - regenerate with /init\n"
    fi
    if hook_installed "$path"; then
        printf "  ${c_dark_gray}[H]${c_reset}  Test hook             - already installed\n"
    else
        printf "  ${c_yellow}[H]${c_reset}  Install test hook     - filter test output to errors only\n"
    fi
    local langs; langs="$(detect_languages "$path")"
    [[ -n "$langs" ]] && printf "  ${c_cyan}[K]${c_reset}  Plugin suggestions    - detected: %s\n" "$langs"
    printf "  ${c_cyan}[E]${c_reset}  Open in Finder\n"
    printf "  ${c_dark_gray}[B]${c_reset}  Back\n"
    echo ""
    write_divider
    printf "  Choose: "
    read -r choice || true
    _MENU_RESULT="$(printf '%s' "${choice:-}" | tr '[:lower:]' '[:upper:]')"
}

# ---------------------------------------------------------------------------
# Project health helpers
# ---------------------------------------------------------------------------

claudemd_status() {
    local path="$1"
    local f="$path/CLAUDE.md"
    if [[ ! -f "$f" ]]; then
        printf "${c_red}missing${c_reset}"
        return
    fi
    local lines; lines="$(wc -l < "$f" | tr -d ' ')"
    if (( lines > 200 )); then
        printf "${c_red}%d lines ⚠ over limit${c_reset}" "$lines"
    elif (( lines > 150 )); then
        printf "${c_yellow}%d lines${c_reset}" "$lines"
    else
        printf "${c_green}%d lines${c_reset}" "$lines"
    fi
}

detect_languages() {
    local path="$1"
    local langs=()
    [[ -f "$path/tsconfig.json" ]]                                            && langs+=("typescript")
    [[ -f "$path/package.json" && ! -f "$path/tsconfig.json" ]]               && langs+=("javascript")
    [[ -f "$path/requirements.txt" || -f "$path/pyproject.toml" || -f "$path/setup.py" ]] && langs+=("python")
    [[ -f "$path/go.mod" ]]    && langs+=("go")
    [[ -f "$path/Cargo.toml" ]] && langs+=("rust")
    [[ -f "$path/pom.xml" || -f "$path/build.gradle" ]] && langs+=("java")
    printf '%s ' "${langs[@]+"${langs[@]}"}"
}

hook_installed() {
    local path="$1"
    local settings="$path/.claude/settings.json"
    [[ -f "$settings" ]] && grep -q "filter-test-output" "$settings" 2>/dev/null
}

install_test_hook() {
    local path="$1"
    local hooks_dir="$HOME/.claude/hooks"
    local hook_script="$hooks_dir/filter-test-output.sh"
    local settings_dir="$path/.claude"
    local settings_file="$settings_dir/settings.json"

    mkdir -p "$hooks_dir" "$settings_dir"

    cat > "$hook_script" << 'HOOKEOF'
#!/bin/bash
input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null)

if [[ "$cmd" =~ ^(npm[[:space:]]test|npm[[:space:]]run[[:space:]]test|pytest|go[[:space:]]test|jest|vitest|mocha) ]]; then
  filtered_cmd="$cmd 2>&1 | grep -A 5 -E '(FAIL|ERROR|error:|FAILED|✕)' | head -100"
  python3 -c "
import json, sys
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'allow','updatedInput':{'command':'$filtered_cmd'}}}))"
else
  echo "{}"
fi
HOOKEOF
    chmod +x "$hook_script"

    # Merge hook into settings.json using python3
    python3 - "$settings_file" "$hook_script" << 'PYEOF'
import json, sys, os

settings_file, hook_script = sys.argv[1], sys.argv[2]

try:
    with open(settings_file) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

hooks = settings.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])

entry = {"matcher": "Bash", "hooks": [{"type": "command", "command": hook_script}]}
if not any(h.get("hooks", [{}])[0].get("command","").endswith("filter-test-output.sh") for h in pre):
    pre.append(entry)

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("ok")
PYEOF
}

list_jig_profiles() {
    if command -v jig &>/dev/null; then
        jig profiles list 2>/dev/null | awk '{print $1}' | grep -v '^$' | tr '\n' ' '
    else
        ls "$SCRIPT_DIR/profiles/"*.json 2>/dev/null | xargs -I{} basename {} .json | tr '\n' ' '
    fi
}

# ---------------------------------------------------------------------------
# Launchers
# ---------------------------------------------------------------------------
assert_dir() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        cecho "$c_red" "  ERROR: Directory not found: $path"
        return 1
    fi
}

assert_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        cecho "$c_red" "  ERROR: '$cmd' is not in PATH. Is it installed?"
        return 1
    fi
}

# Opens a new Terminal window running cmd in dir.
# macOS Terminal automation requires permission on first use (System Settings → Privacy → Automation).
_open_terminal() {
    local dir="$1" cmd="$2"
    local safe_dir="${dir//\'/\'\\\'\'}"
    local safe_cmd="${cmd//\'/\'\\\'\'}"
    osascript &>/dev/null <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "cd '$safe_dir' && $safe_cmd"
end tell
APPLESCRIPT
}

_build_claude_cmd_from_profile() {
    local profile="$1"
    local profile_file="$SCRIPT_DIR/profiles/${profile}.json"
    local cmd="claude"

    if [[ ! -f "$profile_file" ]]; then
        printf '%s' "$cmd"
        return
    fi

    local model perm allowed disallowed
    model="$(jq -r '.model // empty' "$profile_file" 2>/dev/null)"
    perm="$(jq -r '.permissionMode // empty' "$profile_file" 2>/dev/null)"
    allowed="$(jq -r '.allowedTools // [] | map(.) | join(",")' "$profile_file" 2>/dev/null)"
    disallowed="$(jq -r '.disallowedTools // [] | map(.) | join(",")' "$profile_file" 2>/dev/null)"

    [[ -n "$model" ]]      && cmd+=" --model $model"
    [[ "$perm" != "default" && -n "$perm" ]] && cmd+=" --permission-mode $perm"
    [[ -n "$allowed" ]]    && cmd+=" --allowedTools $allowed"
    [[ -n "$disallowed" ]] && cmd+=" --disallowedTools $disallowed"

    printf '%s' "$cmd"
}

launch_with_profile() {
    local path="$1" profile="$2"
    assert_dir "$path" || return
    if command -v jig &>/dev/null; then
        cecho "$c_green" "  Launching jig run $profile in $path ..."
        _open_terminal "$path" "jig run $profile"
    else
        local cmd; cmd="$(_build_claude_cmd_from_profile "$profile")"
        cecho "$c_green" "  Launching: $cmd"
        _open_terminal "$path" "$cmd"
    fi
}

launch_jig() {
    local path="$1"
    assert_dir "$path" || return
    assert_cmd "jig"   || return
    cecho "$c_green" "  Launching Jig in $path ..."
    _open_terminal "$path" "jig"
}

launch_claude() {
    local path="$1"
    assert_dir "$path"  || return
    assert_cmd "claude" || return
    cecho "$c_green" "  Launching claude in $path ..."
    _open_terminal "$path" "claude"
}

launch_resume() {
    local path="$1" session_id="$2"
    assert_dir "$path"  || return
    assert_cmd "claude" || return
    cecho "$c_green" "  Resuming session $session_id ..."
    _open_terminal "$path" "claude --resume $session_id"
}

launch_meta_mission() {
    assert_cmd "jig" || return
    cecho "$c_magenta" "  Launching Meta Mission with planning profile ..."
    _open_terminal "$SCAN_ROOT" "jig run planning"
}

open_finder() {
    local path="$1"
    assert_dir "$path" || return
    open "$path"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
    _detect_json_tool
    load_app_config
    load_config

    local running=true
    _MENU_RESULT=""

    while $running; do
        clear
        show_project_menu
        local raw_up; raw_up="$(printf '%s' "$_MENU_RESULT" | tr '[:lower:]' '[:upper:]')"

        if [[ "$raw_up" == "Q" ]]; then
            echo ""
            cecho "$c_dark_gray" "  Goodbye."
            echo ""
            running=false

        elif [[ "$raw_up" == "M" ]]; then
            launch_meta_mission
            sleep 1

        elif [[ "$raw_up" =~ ^M([0-9]+)$ ]]; then
            local mi=$(( ${BASH_REMATCH[1]} - 1 ))
            local meta_sessions=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && meta_sessions+=("$line")
            done < <(get_recent_sessions "$SCAN_ROOT" 5)
            if (( mi >= 0 && mi < ${#meta_sessions[@]} )); then
                IFS=$'\t' read -r sid _ _ <<< "${meta_sessions[$mi]}"
                launch_resume "$SCAN_ROOT" "$sid"
                sleep 1
            else
                cecho "$c_red" "  Invalid meta session number."
                sleep 1
            fi

        elif [[ "$raw_up" == "S" ]]; then
            clear
            sync_new_projects
            load_config
            printf "  Press Enter to continue"; read -r _

        elif [[ "$_MENU_RESULT" =~ ^[0-9]+$ ]]; then
            local idx=$(( _MENU_RESULT - 1 ))
            if (( idx < 0 || idx >= ${#PROJ_PATHS[@]} )); then
                cecho "$c_red" "  Invalid number."
                sleep 1
            else
                local in_project=true
                while $in_project; do
                    clear
                    write_banner
                    show_launch_menu "$idx"
                    local action="$_MENU_RESULT"

                    if [[ "$action" == "L" ]]; then
                        launch_with_profile "${PROJ_PATHS[$idx]}" "${PROJ_PROFILES[$idx]:-standard}"
                        sleep 1; in_project=false

                    elif [[ "$action" == "J" ]]; then
                        launch_jig "${PROJ_PATHS[$idx]}"
                        sleep 1; in_project=false

                    elif [[ "$action" =~ ^R([0-9]+)$ ]]; then
                        local ri=$(( ${BASH_REMATCH[1]} - 1 ))
                        local sessions=()
                        while IFS= read -r line; do
                            [[ -n "$line" ]] && sessions+=("$line")
                        done < <(get_recent_sessions "${PROJ_PATHS[$idx]}" 5)
                        if (( ri >= 0 && ri < ${#sessions[@]} )); then
                            IFS=$'\t' read -r sid _ _ <<< "${sessions[$ri]}"
                            launch_resume "${PROJ_PATHS[$idx]}" "$sid"
                            sleep 1; in_project=false
                        else
                            cecho "$c_red" "  Invalid session number."
                            sleep 1
                        fi

                    elif [[ "$action" == "N" ]]; then
                        printf "\n  New name [%s]: " "${PROJ_NAMES[$idx]}"
                        read -r new_name || true
                        if [[ -n "$new_name" ]]; then
                            PROJ_NAMES[$idx]="$new_name"
                            save_config
                            cecho "$c_green" "  Renamed to \"$new_name\""
                            sleep 1
                        fi

                    elif [[ "$action" == "P" ]]; then
                        local available_profiles
                        available_profiles="$(list_jig_profiles)"
                        printf "\n  Available profiles: ${c_dark_cyan}%s${c_reset}\n" "$available_profiles"
                        printf "  New profile [%s]: " "${PROJ_PROFILES[$idx]:-standard}"
                        read -r new_profile || true
                        new_profile="${new_profile:-${PROJ_PROFILES[$idx]:-standard}}"
                        if [[ -n "$new_profile" ]]; then
                            PROJ_PROFILES[$idx]="$new_profile"
                            save_config
                            cecho "$c_green" "  Profile updated to [$new_profile]"
                            sleep 1
                        fi

                    elif [[ "$action" == "I" ]]; then
                        assert_cmd "claude" || { sleep 1; continue; }
                        cecho "$c_green" "  Opening claude to run /init in ${PROJ_PATHS[$idx]} ..."
                        cecho "$c_dark_gray" "  Type /init in the session to generate CLAUDE.md, then exit."
                        sleep 1
                        _open_terminal "${PROJ_PATHS[$idx]}" "claude"
                        sleep 1

                    elif [[ "$action" == "H" ]]; then
                        if hook_installed "${PROJ_PATHS[$idx]}"; then
                            cecho "$c_yellow" "  Test hook already installed."
                        else
                            cecho "$c_green" "  Installing test output filter hook..."
                            if install_test_hook "${PROJ_PATHS[$idx]}"; then
                                cecho "$c_green" "  Hook installed: ~/.claude/hooks/filter-test-output.sh"
                                cecho "$c_green" "  Wired into ${PROJ_PATHS[$idx]}/.claude/settings.json"
                            else
                                cecho "$c_red" "  Hook installation failed."
                            fi
                        fi
                        sleep 2

                    elif [[ "$action" == "K" ]]; then
                        local langs; langs="$(detect_languages "${PROJ_PATHS[$idx]}")"
                        echo ""
                        cecho "$c_cyan" "  Detected languages: $langs"
                        echo ""
                        cecho "$c_dark_gray" "  Suggested plugins to install via /plugin in a claude session:"
                        for lang in $langs; do
                            case "$lang" in
                                typescript|javascript) printf "   • TypeScript/JS code intelligence plugin\n" ;;
                                python)  printf "   • Python code intelligence plugin\n" ;;
                                go)      printf "   • Go code intelligence plugin\n" ;;
                                rust)    printf "   • Rust code intelligence plugin\n" ;;
                                java)    printf "   • Java code intelligence plugin\n" ;;
                            esac
                        done
                        echo ""
                        cecho "$c_dark_gray" "  Run /plugin in any claude session to browse the marketplace."
                        printf "  Press Enter to continue"; read -r _ || true

                    elif [[ "$action" == "E" ]]; then
                        open_finder "${PROJ_PATHS[$idx]}"

                    elif [[ "$action" == "B" ]]; then
                        in_project=false

                    else
                        cecho "$c_red" "  Unknown option."
                        sleep 1
                    fi
                done
            fi

        else
            cecho "$c_red" "  Please enter a number, M, S, or Q."
            sleep 1
        fi
    done
}

main "$@"
