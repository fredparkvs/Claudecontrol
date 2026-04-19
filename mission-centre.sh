#!/usr/bin/env bash
# Mission Centre - AI Project Launcher (macOS port)
# Requires: bash 3.2+ or zsh, python3 or jq, jig (optional), claude CLI
set -euo pipefail
export LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/projects.json"
APP_CONFIG_PATH="$SCRIPT_DIR/config.json"
MAX_DEPTH=4
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# ---------------------------------------------------------------------------
# Colors
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

cecho() { local color="$1"; shift; printf "${color}%s${c_reset}\n" "$*"; }
cnecho() { local color="$1"; shift; printf "${color}%s${c_reset}" "$*"; }

# ---------------------------------------------------------------------------
# JSON helper — jq preferred, python3 fallback
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

# Read a top-level string field from a JSON file
# Usage: json_get_field <file> <field>
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

# Read a JSON array from file, output one compact JSON object per line
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

# Get field from a single JSON object string (not a file)
json_obj_field() {
    local obj="$1" field="$2"
    if [[ "$_json_tool" == "jq" ]]; then
        printf '%s' "$obj" | jq -r ".$field // empty" 2>/dev/null
    else
        python3 -c "
import json,sys
try:
    d=json.loads('''$obj''')
    v=d.get('$field','')
    print(v if v else '',end='')
except: pass
" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# App config (config.json — stores scanRoot)
# ---------------------------------------------------------------------------
SCAN_ROOT=""

load_app_config() {
    if [[ -f "$APP_CONFIG_PATH" ]]; then
        local root
        root="$(json_get_field "$APP_CONFIG_PATH" "scanRoot")"
        if [[ -n "$root" ]]; then
            SCAN_ROOT="$root"
            return 0
        fi
    fi

    # First run
    echo ""
    cecho "$c_cyan" "  Welcome to Mission Centre!"
    cecho "$c_dark_gray" "  Enter the root folder to scan for AI projects."
    cecho "$c_dark_gray" "  Example: /Users/you/AI  or  ~/Dev/Projects"
    echo ""
    printf "  Scan root: "
    read -r root
    [[ -z "$root" ]] && root="$SCRIPT_DIR"
    # Expand ~ manually
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
    local name="$1"
    local d
    for d in "${SKIP_DIRS[@]}"; do
        [[ "$name" == "$d" ]] && return 0
    done
    return 1
}

dir_has_definitive_marker() {
    local dir="$1" m
    for m in "${DEFINITIVE_MARKERS[@]}"; do
        [[ -e "$dir/$m" ]] && return 0
    done
    # Also check *.jig glob
    ls "$dir/"*.jig &>/dev/null 2>&1 && return 0
    return 1
}

dir_has_suggestive_marker() {
    local dir="$1" m
    for m in "${SUGGESTIVE_MARKERS[@]}"; do
        [[ -e "$dir/$m" ]] && return 0
    done
    ls "$dir/"*.jig &>/dev/null 2>&1 && return 0
    return 1
}

dir_has_any_marker() {
    dir_has_definitive_marker "$1" && return 0
    dir_has_suggestive_marker "$1" && return 0
    return 1
}

any_child_has_markers() {
    local dir="$1" child
    for child in "$dir"/*/; do
        [[ -d "$child" ]] || continue
        local name="${child%/}"
        name="${name##*/}"
        should_skip_dir "$name" && continue
        dir_has_any_marker "$child" && return 0
    done
    return 1
}

# Outputs discovered project paths, one per line
find_project_dirs() {
    local path="$1" depth="$2"
    (( depth > MAX_DEPTH )) && return
    [[ -d "$path" ]] || return

    local leaf="${path##*/}"
    should_skip_dir "$leaf" && return
    [[ "$path" == "$SCRIPT_DIR" ]] && return

    if dir_has_definitive_marker "$path"; then
        echo "$path"
        return
    fi

    if dir_has_suggestive_marker "$path"; then
        if any_child_has_markers "$path"; then
            : # container — fall through to recurse
        else
            echo "$path"
            return
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

# Arrays parallel-indexed: PROJ_PATH, PROJ_NAME, PROJ_DESC, PROJ_PROFILE
PROJ_PATHS=()
PROJ_NAMES=()
PROJ_DESCS=()
PROJ_PROFILES=()

load_config() {
    PROJ_PATHS=(); PROJ_NAMES=(); PROJ_DESCS=(); PROJ_PROFILES=()
    [[ -f "$CONFIG_PATH" ]] || return

    local line path name desc profile
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$_json_tool" == "jq" ]]; then
            path="$(printf '%s' "$line" | jq -r '.path // empty')"
            name="$(printf '%s' "$line" | jq -r '.name // empty')"
            desc="$(printf '%s' "$line" | jq -r '.description // empty')"
            profile="$(printf '%s' "$line" | jq -r '.profile // "standard"')"
        else
            path="$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('path',''))")"
            name="$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('name',''))")"
            desc="$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('description',''))")"
            profile="$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('profile','standard'))")"
        fi
        [[ -z "$path" ]] && continue
        PROJ_PATHS+=("$path")
        PROJ_NAMES+=("$name")
        PROJ_DESCS+=("$desc")
        PROJ_PROFILES+=("$profile")
    done < <(json_array_lines "$CONFIG_PATH")
}

save_config() {
    local i out="["
    local count=${#PROJ_PATHS[@]}
    for (( i=0; i<count; i++ )); do
        [[ $i -gt 0 ]] && out+=","
        local today; today="$(date +%Y-%m-%d)"
        if [[ "$_json_tool" == "jq" ]]; then
            local entry
            entry="$(jq -n \
                --arg path "${PROJ_PATHS[$i]}" \
                --arg name "${PROJ_NAMES[$i]}" \
                --arg desc "${PROJ_DESCS[$i]}" \
                --arg prof "${PROJ_PROFILES[$i]}" \
                --arg added "$today" \
                '{path:$path,name:$name,description:$desc,added:$added,profile:$prof}')"
            out+="$entry"
        else
            out+="$(python3 -c "
import json
print(json.dumps({'path':'${PROJ_PATHS[$i]//\'/\\\'}','name':'${PROJ_NAMES[$i]//\'/\\\'}','description':'${PROJ_DESCS[$i]//\'/\\\'}','added':'$today','profile':'${PROJ_PROFILES[$i]//\'/\\\'}'}),end='')
")"
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

    local discovered=()
    while IFS= read -r p; do
        discovered+=("$p")
    done < <(find_project_dirs "$SCAN_ROOT" 0)

    local new_paths=()
    local p
    for p in "${discovered[@]+"${discovered[@]}"}"; do
        config_has_path "$p" || new_paths+=("$p")
    done

    if [[ ${#new_paths[@]} -eq 0 ]]; then
        cecho "$c_dark_gray" "No new projects found."
        return
    fi

    echo ""
    cecho "$c_yellow" "Found ${#new_paths[@]} new project(s) not yet in config."
    printf '\033[90m%s\033[0m\n' "$(printf '%0.s─' {1..46})"

    for p in "${new_paths[@]}"; do
        local default_name="${p##*/}"
        echo ""
        cnecho "$c_cyan" "  New project: "; echo "$p"
        printf "  Name        [%s]: " "$default_name"; read -r name
        [[ -z "$name" ]] && name="$default_name"
        printf "  Description (one line, or Enter to skip): "; read -r desc
        [[ -z "$desc" ]] && desc="- no description yet -"
        cecho "$c_dark_cyan" "  Profiles: corporate, vibe, build, maintain, review, standard"
        printf "  Profile     [standard]: "; read -r prof
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
encode_path() {
    printf '%s' "$1" | sed 's|[/ ]|-|g'
}

# Parse up to 150 lines of a .jsonl session file
# Outputs the best label: custom-title preferred, then first user message
get_session_label() {
    local file="$1"
    [[ -f "$file" ]] || return

    python3 - "$file" <<'PYEOF'
import json, sys

path = sys.argv[1]
custom_title = None
first_prompt = None

try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for i, line in enumerate(f):
            if i >= 150:
                break
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue

            if not custom_title and msg.get('type') == 'custom-title' and msg.get('customTitle'):
                custom_title = msg['customTitle'].replace('-', ' ')

            if not first_prompt:
                # Format A: {"type":"user","message":{"content":...}}
                if msg.get('type') in ('user', 'human') and isinstance(msg.get('message'), dict):
                    c = msg['message'].get('content', '')
                    if isinstance(c, list):
                        for b in c:
                            if isinstance(b, dict) and b.get('type') == 'text' and b.get('text'):
                                first_prompt = str(b['text'])
                                break
                    elif c:
                        first_prompt = str(c)
                # Format C: {"role":"user","content":...}
                if not first_prompt and msg.get('role') == 'user' and msg.get('content'):
                    c = msg['content']
                    if isinstance(c, list):
                        for b in c:
                            if isinstance(b, dict) and b.get('type') == 'text' and b.get('text'):
                                first_prompt = str(b['text'])
                                break
                    elif isinstance(c, str):
                        first_prompt = c

            if custom_title and first_prompt:
                break
except Exception:
    pass

result = custom_title if custom_title else first_prompt
if result:
    print(result, end='')
PYEOF
}

# Outputs sessions as tab-separated lines: sessionId\tfileMtime\tlabel
# Usage: get_recent_sessions <project_path> [max_count]
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
    entries = entries[:max_count]
    for e in entries:
        sid = e.get('sessionId') or e.get('id', '')
        if not sid: continue
        mtime = int(e.get('fileMtime', 0))
        summary = e.get('summary', '') or ''
        label = summary if summary else (get_label(folder_path, sid) or '(no prompt captured)')
        # sanitize tabs in label
        label = label.replace('\t', ' ').replace('\n', ' ')[:200]
        print(f'{sid}\t{mtime}\t{label}')
except Exception as ex:
    pass
PYEOF
        return
    fi

    # Fallback: scan .jsonl files directly
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
    python3 - "$mtime_ms" <<'PYEOF'
import sys, datetime

ms = int(sys.argv[1])
if ms <= 0:
    print('?', end=''); sys.exit()

mod = datetime.datetime.fromtimestamp(ms / 1000)
diff = datetime.datetime.now() - mod
total_s = diff.total_seconds()

if total_s < 3600:
    print(f'{int(total_s/60)}m ago', end='')
elif total_s < 86400:
    print(f'{int(total_s/3600)}h ago', end='')
elif total_s < 86400*30:
    print(f'{int(total_s/86400)}d ago', end='')
else:
    print(mod.strftime('%Y-%m-%d'), end='')
PYEOF
}

truncate_str() {
    local s="$1" max="${2:-55}"
    if (( ${#s} > max )); then
        printf '%s...' "${s:0:$((max-3))}"
    else
        printf '%s' "$s"
    fi
}

# ---------------------------------------------------------------------------
# Banner & UI
# ---------------------------------------------------------------------------
write_banner() {
    local inner=44
    local title="  MISSION CENTRE  "
    printf "${c_cyan}╔$(printf '═%.0s' $(seq 1 $inner))╗${c_reset}\n"
    local pad_total=$(( inner - ${#title} ))
    local pad_l=$(( pad_total / 2 ))
    local pad_r=$(( pad_total - pad_l ))
    printf "${c_cyan}║%*s%s%*s║${c_reset}\n" $pad_l "" "$title" $pad_r ""
    printf "${c_cyan}╚$(printf '═%.0s' $(seq 1 $inner))╝${c_reset}\n"
    echo ""
}

write_divider() {
    printf "${c_dark_gray}$(printf '─%.0s' $(seq 1 46))${c_reset}\n"
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

    # Recent meta sessions from scan root
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
    read -r choice
    printf '%s' "${choice:-}"
}

show_launch_menu() {
    local idx="$1"
    local path="${PROJ_PATHS[$idx]}"
    local name="${PROJ_NAMES[$idx]}"
    local profile="${PROJ_PROFILES[$idx]:-standard}"

    echo ""
    printf "  ${c_dark_gray}Project : ${c_reset}${c_cyan}%s${c_reset}  ${c_dark_cyan}[%s]${c_reset}\n" "$name" "$profile"
    printf "  ${c_dark_gray}Path    : %s${c_reset}\n\n" "$path"

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

    printf "  ${c_green}[L]${c_reset}  Launch                - jig run %s (project default)\n" "$profile"
    printf "  ${c_yellow}[J]${c_reset}  Launch with Jig       - pick a different profile\n"
    [[ ${#sessions[@]} -gt 0 ]] && \
        printf "  ${c_green}[R#]${c_reset} Resume mission        - resume a session listed above\n"
    printf "  ${c_cyan}[E]${c_reset}  Open in Finder\n"
    printf "  ${c_dark_gray}[B]${c_reset}  Back\n"
    echo ""
    write_divider
    printf "  Choose: "
    read -r choice
    printf '%s' "${choice:-}" | tr '[:lower:]' '[:upper:]'
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

# Open a new Terminal window running a command in the given directory.
# Handles paths with spaces via AppleScript quoting.
_open_terminal() {
    local dir="$1" cmd="$2"
    # Escape single quotes for AppleScript string embedding
    local safe_dir="${dir//\'/\'\\\'\'}"
    local safe_cmd="${cmd//\'/\'\\\'\'}"
    osascript -e "tell application \"Terminal\" to do script \"cd '$safe_dir' && $safe_cmd\"" &>/dev/null
}

launch_with_profile() {
    local path="$1" profile="$2"
    assert_dir "$path" || return
    assert_cmd "jig" || return
    cecho "$c_green" "  Launching jig run $profile in $path ..."
    _open_terminal "$path" "jig run $profile"
}

launch_jig() {
    local path="$1"
    assert_dir "$path" || return
    assert_cmd "jig" || return
    cecho "$c_green" "  Launching Jig in $path ..."
    _open_terminal "$path" "jig"
}

launch_resume() {
    local path="$1" session_id="$2"
    assert_dir "$path" || return
    assert_cmd "claude" || return
    cecho "$c_green" "  Resuming session $session_id ..."
    _open_terminal "$path" "claude --resume $session_id"
}

launch_meta_mission() {
    assert_cmd "jig" || return
    cecho "$c_magenta" "  Launching Meta Mission with build profile ..."
    _open_terminal "$SCAN_ROOT" "jig run build"
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

    while $running; do
        clear
        local raw; raw="$(show_project_menu)"
        local raw_up; raw_up="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"

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

        elif [[ "$raw" =~ ^[0-9]+$ ]]; then
            local idx=$(( raw - 1 ))
            if (( idx < 0 || idx >= ${#PROJ_PATHS[@]} )); then
                cecho "$c_red" "  Invalid number."
                sleep 1
            else
                local in_project=true
                while $in_project; do
                    clear
                    write_banner
                    local action; action="$(show_launch_menu "$idx")"

                    if [[ "$action" == "L" ]]; then
                        local prof="${PROJ_PROFILES[$idx]:-standard}"
                        launch_with_profile "${PROJ_PATHS[$idx]}" "$prof"
                        sleep 1
                        in_project=false

                    elif [[ "$action" == "J" ]]; then
                        launch_jig "${PROJ_PATHS[$idx]}"
                        sleep 1
                        in_project=false

                    elif [[ "$action" =~ ^R([0-9]+)$ ]]; then
                        local ri=$(( ${BASH_REMATCH[1]} - 1 ))
                        local sessions=()
                        while IFS= read -r line; do
                            [[ -n "$line" ]] && sessions+=("$line")
                        done < <(get_recent_sessions "${PROJ_PATHS[$idx]}" 5)
                        if (( ri >= 0 && ri < ${#sessions[@]} )); then
                            IFS=$'\t' read -r sid _ _ <<< "${sessions[$ri]}"
                            launch_resume "${PROJ_PATHS[$idx]}" "$sid"
                            sleep 1
                            in_project=false
                        else
                            cecho "$c_red" "  Invalid session number."
                            sleep 1
                        fi

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
