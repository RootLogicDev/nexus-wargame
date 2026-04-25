#!/usr/bin/env bash
# =============================================================================
# NEXUS WARGAME v1.1.2 — Operation: Zero Day  (MAXIMUM HARDENED)
# 20 levels | Cross-platform | Anti-cheat | Core storage | Safe state | Sandbox
#
# [v1.1.2 UPGRADES over v1.1.1]
#  UP-1   Variable password lengths (16–28 chars) — harder to pattern-match
#  UP-2   gen_fake_pass() — lookalike decoy passwords in every level
#  UP-3   Hidden core storage (~/.nexus/.core/) for .hash and .plain files
#  UP-4   _read_core() — chmod 000 protection, temp unlock for internal reads
#  UP-5   Safe state parser — replaces 'source state' with key-whitelist parser
#  UP-6   Soft sandboxing — cd override in game shell restricts navigation
#  UP-7   Passive cheat logging — DEBUG trap writes to ~/.nexus/logs/.cmdlog
#  UP-8   Portable nc — replaced -lvnp/-lp with universally compatible flags
#  UP-9   Level honeypots — fake paths, lookalike passwords, multi-step traps
#  UP-10  Hints toned down — light insight only, no complete solutions
#  UP-11  Post-setup permission hardening — core files chmod 000 after build
#  UP-12  Log directory created and secured during setup
#  UP-13  Environment hardening — core paths unexported from game shell env
#
# USAGE:
#   bash wargame.sh setup           — build environment (run once)
#   bash wargame.sh play            — start / continue
#   bash wargame.sh play --timed    — timed mode (per-level budget)
#   bash wargame.sh status          — progress + visual bar
#   bash wargame.sh verify          — check installation integrity
#   bash wargame.sh leaderboard     — top scores
#   bash wargame.sh report          — export completion certificate
#   bash wargame.sh reset           — wipe progress
# =============================================================================

GAME_DIR="$HOME/.nexus"
LEVELS_DIR="$GAME_DIR/levels"
SAVE_DIR="$GAME_DIR/save"
# [UPGRADE UP-3] Sensitive files stored separately from challenge dirs
CORE_DIR="$GAME_DIR/.core"
TOTAL_LEVELS=20
VERSION="1.1.2"
NET_PORT=4444
TIMED_MODE=0

# [FIX-9 from v3.1.1] Machine-specific integrity salt
_STATE_SALT="NX${VERSION}:$(uname -n 2>/dev/null | tr -d '\n' | head -c 16 || echo 'NEXUS')"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m' B='\033[1;34m'
C='\033[1;36m' M='\033[1;35m' W='\033[1;37m' D='\033[2m' N='\033[0m'

pi() { echo -e "${C}[*]${N} $*"; }
pg() { echo -e "${G}[+]${N} $*"; }
pe() { echo -e "${R}[!]${N} $*" >&2; }
pw() { echo -e "${Y}[~]${N} $*"; }

# ── Core helpers ──────────────────────────────────────────────────────────────

# [UPGRADE UP-1] Variable password length (16-28 chars) — breaks pattern matching
gen_pass() {
    local len=$(( (RANDOM % 13) + 16 ))
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len"
}

# [UPGRADE UP-2] Generate visually convincing fake password
# Uses same character set but subtly wrong — lookalike chars, similar length
gen_fake_pass() {
    local ref_len="${1:-20}"
    # Vary length by ±2 to avoid trivial length-based filtering
    local len=$(( ref_len + (RANDOM % 5) - 2 ))
    [[ $len -lt 14 ]] && len=14
    local raw
    raw=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len")
    # Inject subtle lookalike substitutions: 0↔O, 1↔l, rn≈m
    # These confuse players who read quickly without careful inspection
    echo "$raw" | tr 'OIl' '01l'
}

hash_pass() { echo -n "$1" | sha256sum | awk '{print $1}'; }

hint_cost() {
    local c=$(( 10#${1:-1} * 5 ))
    echo $(( c > 40 ? 40 : c ))
}

# Per-level timed budget: L01-04=3m, L05-09=5m, L10-14=7m, L15-20=10m
level_time_limit() {
    local n; n=$(( 10#${1:-1} ))
    if   [[ $n -le 4  ]]; then echo 180
    elif [[ $n -le 9  ]]; then echo 300
    elif [[ $n -le 14 ]]; then echo 420
    else                        echo 600
    fi
}

# Portable line shuffle — works on busybox awk, gawk, mawk; no sort -R
_shuffle_lines() {
    awk 'BEGIN{srand()}{printf "%07d\t%s\n", int(rand()*9999999), $0}' | \
        sort -n | cut -f2-
}

# =============================================================================
# [UPGRADE UP-3/UP-4] HIDDEN CORE STORAGE + PROTECTED FILE ACCESS
# .hash and .plain files live in ~/.nexus/.core/ with chmod 000
# _read_core() temporarily grants read access for internal operations only
# =============================================================================

# [UPGRADE UP-4] Temporarily unlock a core file, read it, re-lock immediately
# This lets game internals read while preventing casual player access
_read_core() {
    local file="$1"
    [[ ! -e "$file" ]] && return 1
    chmod 400 "$file" 2>/dev/null
    local content
    content=$(cat "$file" 2>/dev/null)
    chmod 000 "$file" 2>/dev/null
    printf '%s' "$content"
}

# =============================================================================
# [UPGRADE UP-5] SAFE STATE LOADING — replaces 'source state_file'
# Whitelist parser: only named keys accepted, types validated, no code execution
# =============================================================================

_safe_load_state() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    local key value
    while IFS='=' read -r key value; do
        # Skip blank lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Strip whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Strip surrounding quotes from value
        value="${value%\"}" ; value="${value#\"}"
        case "$key" in
            LEVEL)
                [[ "$value" =~ ^[0-9]{1,2}$ ]] && LEVEL="$value" ;;
            SCORE)
                [[ "$value" =~ ^[0-9]+$ ]] && SCORE="$value" ;;
            ACHIEVEMENTS)
                # [FIX] Regex rejected em-dash in labels causing checksum
                # mismatch on every load -> infinite reset to level 01.
                # Block only actual shell execution metacharacters.
                if [[ "$value" != *'$('* && "$value" != *'\`'* && \
                      "$value" != *';'*  && "$value" != *$'\n'* ]]; then
                    ACHIEVEMENTS="$value"
                fi ;;
            SPEEDRUN)
                [[ "$value" =~ ^[01]$ ]] && SPEEDRUN="$value" ;;
            SR_START)
                [[ "$value" =~ ^[0-9]*$ ]] && SR_START="$value" ;;
            SR_BEST)
                [[ "$value" =~ ^[0-9]*$ ]] && SR_BEST="$value" ;;
            COMPLETED)
                [[ "$value" =~ ^[01]$ ]] && COMPLETED="$value" ;;
            HINTS_L[0-9]*)
                local lvl_num="${key#HINTS_L}"
                [[ "$lvl_num" =~ ^[0-9]{1,2}$ && "$value" =~ ^[0-9]+$ ]] && \
                    eval "HINTS_L${lvl_num}=${value}" ;;
            CHECKSUM)
                [[ "$value" =~ ^[a-f0-9]{64}$ ]] && CHECKSUM="$value" ;;
            # All other keys silently ignored — no arbitrary execution
        esac
    done < "$file"
    return 0
}

# =============================================================================
# STATE SECURITY — INTEGRITY CHECKSUM (preserved from v3.1.1)
# =============================================================================

_state_checksum() {
    local hints_str=""
    local i
    for i in $(seq -w 1 20); do
        local vn="HINTS_L${i}"
        hints_str+="${!vn:-0},"
    done
    printf '%s' "${_STATE_SALT}|${LEVEL}|${SCORE}|${ACHIEVEMENTS}|${SPEEDRUN}|${hints_str}" \
        | sha256sum | awk '{print $1}'
}

_init_hint_vars() {
    local i
    for i in $(seq -w 1 20); do eval "HINTS_L${i}=0"; done
}

load_state() {
    LEVEL="01"; SCORE=0; ACHIEVEMENTS=""
    SPEEDRUN=0; SR_START=""; SR_BEST=""; COMPLETED=0
    CHECKSUM=""
    _init_hint_vars

    if [[ -f "$SAVE_DIR/state" ]]; then
        # [UPGRADE UP-5] Use safe parser instead of 'source'
        _safe_load_state "$SAVE_DIR/state"
        local stored_chk="${CHECKSUM:-}"
        if [[ -n "$stored_chk" ]]; then
            local computed_chk; computed_chk=$(_state_checksum)
            if [[ "$stored_chk" != "$computed_chk" ]]; then
                pe "STATE INTEGRITY VIOLATION DETECTED"
                pe "Progress has been tampered with or corrupted."
                pw "Resetting all progress to enforce system authority."
                sleep 2
                LEVEL="01"; SCORE=0; ACHIEVEMENTS=""
                SPEEDRUN=0; SR_START=""; SR_BEST=""; COMPLETED=0
                _init_hint_vars
                save_state
            fi
        else
            save_state
        fi
    fi
}

save_state() {
    mkdir -p "$SAVE_DIR"
    local chk; chk=$(_state_checksum)
    {
        printf 'LEVEL="%s"\n'        "$LEVEL"
        printf 'SCORE=%d\n'          "$SCORE"
        printf 'ACHIEVEMENTS="%s"\n' "$ACHIEVEMENTS"
        printf 'SPEEDRUN=%d\n'       "$SPEEDRUN"
        printf 'SR_START="%s"\n'     "$SR_START"
        printf 'SR_BEST="%s"\n'      "${SR_BEST:-}"
        printf 'COMPLETED=%d\n'      "$COMPLETED"
        local i
        for i in $(seq -w 1 20); do
            local vn="HINTS_L${i}"
            printf 'HINTS_L%s=%d\n' "$i" "${!vn:-0}"
        done
        printf 'CHECKSUM="%s"\n' "$chk"
    } > "$SAVE_DIR/state"
}

give_achievement() {
    local id="$1" label="$2"
    [[ "$ACHIEVEMENTS" == *"|$id|"* ]] && return
    ACHIEVEMENTS="${ACHIEVEMENTS}|${id}:${label}|"
    save_state
    echo -e "\n${Y}  ╔══════════════════════════════════════════════╗"
    printf   "  ║  🏆  ACHIEVEMENT: %-26s║\n" " $label"
    echo -e  "  ╚══════════════════════════════════════════════╝${N}\n"
    sleep 1
}

# ── Banner / Progress / Grade ─────────────────────────────────────────────────
banner() {
    clear; echo -e "${R}"
    cat << 'BANNER'
 ███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗
 ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝
 ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗
 ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║
 ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║
 ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
BANNER
    echo -e "${D}          OPERATION: ZERO DAY  v${VERSION}${N}"
    echo -e "${R}───────────────────────────────────────────${N}\n"
}

progress_bar() {
    local current=$(( 10#${LEVEL:-1} - 1 ))
    local total=$TOTAL_LEVELS width=26
    local filled=$(( current * width / total )) bar="" pct=$(( current * 100 / total ))
    for ((i=0;i<filled;i++));     do bar+="█"; done
    for ((i=filled;i<width;i++)); do bar+="░"; done
    printf "  ${C}[${G}%s${C}]${N} %d%% (%d/%d)\n" "$bar" "$pct" "$current" "$total"
}

get_grade() {
    local s=$1 max=$(( TOTAL_LEVELS * 100 ))
    local pct=$(( s * 100 / max ))
    if   [[ $pct -ge 90 ]]; then echo "S-RANK — ELITE"
    elif [[ $pct -ge 80 ]]; then echo "A-RANK — EXPERT"
    elif [[ $pct -ge 65 ]]; then echo "B-RANK — PROFICIENT"
    elif [[ $pct -ge 50 ]]; then echo "C-RANK — DEVELOPING"
    else                         echo "D-RANK — BEGINNER"; fi
}

# =============================================================================
# LEVEL BUILDER HELPERS
# =============================================================================

# [UPGRADE UP-3] mkl writes hash/plain to CORE_DIR, not level directory
mkl() {
    local n="$1" pass="$2" plain="${3:-0}"
    mkdir -p "$LEVELS_DIR/level$n/challenge"
    mkdir -p "$CORE_DIR"
    # [UPGRADE UP-3] Hash stored in hidden core directory
    hash_pass "$pass" > "$CORE_DIR/$n.hash"
    chmod 600 "$CORE_DIR/$n.hash"   # will be chmod 000 after setup completes
    echo "0" > "$LEVELS_DIR/level$n/hint_pos"
    echo "0" > "$LEVELS_DIR/level$n/.attempts"
    [[ "$plain" == "1" ]] && {
        echo "$pass" > "$CORE_DIR/$n.plain"
        chmod 600 "$CORE_DIR/$n.plain"  # will be chmod 000 after setup completes
    }
}

meta() {
    local n="$1" obj="$2" narr="$3"; shift 3
    printf '%b\n' "$obj"  > "$LEVELS_DIR/level$n/objective"
    printf '%b\n' "$narr" > "$LEVELS_DIR/level$n/narrative"
    printf '%s\n' "$@"    > "$LEVELS_DIR/level$n/hints"
}

# =============================================================================
# LEVEL BUILDERS — HARDENED WITH HONEYPOTS AND VARIABLE PASSWORDS
# =============================================================================

# ── Level 01 — BOOT_SECTOR ────────────────────────────────────────────────────
# [UPGRADE UP-9] Added decoy README.bak with lookalike fake password
build_l01() {
    mkl "01" "$1"
    local d="$LEVELS_DIR/level01/challenge"
    echo "$1"                    > "$d/README"
    # [UPGRADE UP-9] Honeypot: same filename with extension, wrong content
    echo "$(gen_fake_pass ${#1})" > "$d/README.bak"
    echo "$(gen_fake_pass ${#1})" > "$d/README~"
    meta "01" \
"Read the file named README in your working directory." \
"BOOT_SECTOR\n\nYour terminal flickers to life.\nThe Architect left a message. File: README.\nOther files may distract you. Stay focused." \
"What command reads a file's contents to standard output?" \
"The command takes a filename as an argument. Think about what 'README' typically contains." \
"You need the exact file — not a backup or a temp file. Filename matters."
}

# ── Level 02 — NEGATIVE_SPACE ─────────────────────────────────────────────────
# [UPGRADE UP-9] Added more plausible decoy files; objective less direct
build_l02() {
    mkl "02" "$1"
    local d="$LEVELS_DIR/level02/challenge"
    echo "$1"                     > "$d/-"
    echo "nothing useful here"    > "$d/README"
    echo "$(gen_fake_pass ${#1})" > "$d/data"
    echo "$(gen_fake_pass ${#1})" > "$d/output"
    echo "empty"                  > "$d/log"
    meta "02" \
"A file in this directory holds the password. Its name is a single character.\nReading it with the obvious approach will not work." \
"NEGATIVE_SPACE\n\nOne character. That is the filename.\nYour instinct will betray you.\nThe shell will interpret it differently than you expect.\nThink about what that character means to programs." \
"What does a lone dash typically signal to command-line programs?" \
"There is a way to force the shell to treat an argument as a file path rather than a flag." \
"Consider how you specify that something is a path relative to the current directory."
}

# ── Level 03 — WHITESPACE ─────────────────────────────────────────────────────
# [UPGRADE UP-9] Extra decoys; hint3 no longer names the approach
build_l03() {
    mkl "03" "$1"
    local d="$LEVELS_DIR/level03/challenge"
    echo "$1"                     > "$d/access code"
    echo "$(gen_fake_pass ${#1})" > "$d/accesscode"
    echo "$(gen_fake_pass ${#1})" > "$d/access_code"
    echo "$(gen_fake_pass ${#1})" > "$d/ACCESS_CODE"
    echo "$(gen_fake_pass ${#1})" > "$d/access.code"
    echo "$(gen_fake_pass ${#1})" > "$d/Access Code"
    cat > "$d/MANIFEST" << 'LEOF'
FILE MANIFEST
=============
Six data files present.
One contains the credential.
Its name contains a whitespace character.
Standard argument passing will fail.
LEOF
    meta "03" \
"One file in this directory has a space in its name and contains the password.\nStandard argument syntax will fail silently or target the wrong file." \
"WHITESPACE\n\nSix files. Five are noise.\nOne has a space embedded in its name.\nThe shell splits arguments on whitespace by default.\nYou must override that behavior to reach it." \
"How does the shell parse command arguments that contain spaces?" \
"There are two standard ways to prevent the shell from splitting on whitespace." \
"One method wraps the entire argument. The other escapes the specific character."
}

# ── Level 04 — SPECTER ────────────────────────────────────────────────────────
# [UPGRADE UP-9] More hidden decoys, one with near-identical prefix
build_l04() {
    mkl "04" "$1"
    local d="$LEVELS_DIR/level04/challenge"
    local real_len=${#1}
    echo "$1"                               > "$d/.classified"
    echo "$(gen_fake_pass "$real_len")"     > "$d/.classified_v1"
    echo "REVOKED_$(gen_fake_pass 12)"      > "$d/.classified_backup"
    echo "$(gen_fake_pass "$real_len")"     > "$d/.classified_current"
    printf 'status=expired\nts=1709823600\n' > "$d/.metadata"
    echo "ARCHIVE_$(gen_fake_pass 10)"      > "$d/.archive"
    echo "decoy"  > "$d/report.txt"
    echo "decoy"  > "$d/notes.txt"
    echo "decoy"  > "$d/summary.txt"
    cat > "$d/NOTICE" << 'LEOF'
CLASSIFIED FILES
================
Hidden files present. Standard listing conceals them.
Not all hidden files contain valid credentials.
Some are expired. Some are decoys. One is current.
Enumerate all. Assess each. Submit only the active one.
LEOF
    # [UPGRADE UP-10] Hint no longer names '.classified' directly
    meta "04" \
"Multiple hidden files exist. Only one contains a valid access code.\nFind and enumerate all hidden files, then identify and read the correct one." \
"SPECTER\n\nDot-prefix files are invisible to plain ls.\nSeveral exist here. Not all are real.\nYou need the one that is current and active.\nEnumerate everything. Assess what you find." \
"What ls flag reveals ALL files including those whose names begin with '.' ?" \
"Use ls with the flag that disables the default hidden-file filter. Read every result." \
"Valid credentials have a specific character set and length. Expired ones are labeled. Trust your eyes."
}

# ── Level 05 — FORENSICS ──────────────────────────────────────────────────────
# [UPGRADE UP-9] Randomized target; added an extra ASCII text decoy with wrong content
build_l05() {
    mkl "05" "$1"
    local d="$LEVELS_DIR/level05/challenge"
    local tgt=$(( RANDOM % 8 ))          # target in slots 0-7
    local decoy_slot=$(( tgt + 1 + RANDOM % 2 ))  # decoy ASCII file near target
    [[ $decoy_slot -gt 9 ]] && decoy_slot=$(( tgt - 1 ))
    local i fname
    for i in $(seq 0 9); do
        printf -v fname "data%02d" "$i"
        if [[ $i -eq $tgt ]]; then
            echo "$1" > "$d/$fname"
        elif [[ $i -eq $decoy_slot ]]; then
            # [UPGRADE UP-9] Second ASCII file with wrong content — traps hasty players
            echo "$(gen_fake_pass ${#1})" > "$d/$fname"
        else
            head -c $(( RANDOM % 400 + 200 )) /dev/urandom > "$d/$fname" 2>/dev/null
        fi
    done
    # [UPGRADE UP-10] Hint no longer says "look for ASCII text"
    meta "05" \
"Ten files. Most will damage your terminal if read directly.\nOne contains the password as human-readable text.\nIdentify the correct file without opening each one." \
"FORENSICS\n\nTen files. Most are traps.\nOpening the wrong ones will corrupt your terminal.\nIdentify before you read — that is the only safe approach.\nNot every readable file contains the real answer." \
"Is there a command that reveals what a file actually contains before you open it?" \
"This command inspects the first bytes of a file and reports its true type." \
"Use it on all files at once. Then decide which one to actually read."
}

# ── Level 06 — INTERCEPT ──────────────────────────────────────────────────────
# [UPGRADE UP-9] Added fake cfg_token decoy lines with wrong values
build_l06() {
    mkl "06" "$1"
    local d="$LEVELS_DIR/level06/challenge"
    local decoys=("CONN_STATUS=active" "CONN_HOST=10.0.0.1" "CONN_PORT=8443"
                   "CONN_RETRY=3" "CONN_TIMEOUT=30" "cfg_user=svc_nexus"
                   "cfg_host=db-primary" "cfg_port=5432" "cfg_ssl=true"
                   "cfg_pool=10")
    {
        for i in $(seq 1 120); do
            local ts; ts=$(awk 'BEGIN{
                srand('"$RANDOM"');
                printf "2024-%02d-%02dT%02d:%02d:%02d",
                    int(rand()*11+1), int(rand()*27+1),
                    int(rand()*23), int(rand()*59), int(rand()*59)
            }')
            printf 'EVENT_%05d [%s] INFO  %s\n' \
                "$i" "$ts" "${decoys[$((RANDOM % ${#decoys[@]}))]} noise_$RANDOM"
        done
        # [UPGRADE UP-9] Fake cfg_token entries to trap hasty grep users
        local fake_ts1; fake_ts1=$(awk 'BEGIN{srand('"$RANDOM"'); printf "2024-%02d-%02dT%02d:%02d:%02d",int(rand()*11+1),int(rand()*27+1),int(rand()*23),int(rand()*59),int(rand()*59)}')
        printf 'EVENT_%05d [%s] DEBUG cfg_token=%s token_type=refresh_only\n' \
            "121" "$fake_ts1" "$(gen_fake_pass 22)"
        for i in $(seq 122 240); do
            local ts; ts=$(awk 'BEGIN{
                srand('"$RANDOM"');
                printf "2024-%02d-%02dT%02d:%02d:%02d",
                    int(rand()*11+1), int(rand()*27+1),
                    int(rand()*23), int(rand()*59), int(rand()*59)
            }')
            printf 'EVENT_%05d [%s] INFO  %s\n' \
                "$i" "$ts" "${decoys[$((RANDOM % ${#decoys[@]}))]} noise_$RANDOM"
        done
        # Real token — WARN level, session_validated=true distinguishes it
        printf 'EVENT_%05d [2024-01-15T03:17:44] WARN  cfg_token=%s session_validated=true\n' \
            "241" "$1"
        local fake_ts2; fake_ts2=$(awk 'BEGIN{srand('"$RANDOM"'); printf "2024-%02d-%02dT%02d:%02d:%02d",int(rand()*11+1),int(rand()*27+1),int(rand()*23),int(rand()*59),int(rand()*59)}')
        printf 'EVENT_%05d [%s] DEBUG cfg_token=%s token_type=read_only expired=true\n' \
            "242" "$fake_ts2" "$(gen_fake_pass 18)"
        for i in $(seq 243 499); do
            local ts; ts=$(awk 'BEGIN{
                srand('"$RANDOM"');
                printf "2024-%02d-%02dT%02d:%02d:%02d",
                    int(rand()*11+1), int(rand()*27+1),
                    int(rand()*23), int(rand()*59), int(rand()*59)
            }')
            printf 'EVENT_%05d [%s] INFO  %s\n' \
                "$i" "$ts" "${decoys[$((RANDOM % ${#decoys[@]}))]} noise_$RANDOM"
        done
    } > "$d/intercept.log"
    # [UPGRADE UP-10] Hint no longer names the exact field or grep pattern
    meta "06" \
"Search intercept.log for the line containing a live credential value.\nMultiple lines may look relevant — only one is active." \
"INTERCEPT\n\n499 lines of intercepted traffic.\nSome entries are decoys. Some are expired.\nOnly one credential is live and session-validated.\nThe log structure will reveal which is real." \
"What command searches for a text pattern across lines of a file?" \
"Use grep to find lines matching a token pattern. Not every match is valid." \
"Look at the log level and additional fields on each matching line to distinguish real from fake."
}

# ── Level 07 — FREQUENCY ──────────────────────────────────────────────────────
# Deterministic fill preserved; shuffle seeds differ per build
build_l07() {
    mkl "07" "$1"
    local d="$LEVELS_DIR/level07/challenge"
    {
        for sig in $(seq -w 00 14); do
            for _ in $(seq 1 8); do
                printf 'SIG_ECHO_%s\n' "$sig"
            done
        done
        echo "$1"
    } | _shuffle_lines > "$d/frequency.dat"
    meta "07" \
"Find the one line in frequency.dat that appears exactly once.\nAll other lines repeat multiple times." \
"FREQUENCY\n\nNoise. Repetition. Signal.\nThe data is shuffled — adjacent-line tools will not work without preprocessing.\nSort first. Then filter.\nTwo commands. One pipe. One result." \
"What tool filters lines based on how many times they appear?" \
"That tool has a flag that outputs only lines appearing exactly once — but it needs sorted input first." \
"Think about what happens when you sort before filtering for uniqueness."
}

# ── Level 08 — DECODE_ALPHA ───────────────────────────────────────────────────
# [UPGRADE UP-9] Added second encoded file with wrong content as decoy
build_l08() {
    mkl "08" "$1"
    local d="$LEVELS_DIR/level08/challenge"
    echo "$1" | base64 > "$d/payload.dat"
    # [UPGRADE UP-9] Decoy: also base64 but wrong content
    echo "$(gen_fake_pass ${#1})" | base64 > "$d/payload.dat.bak"
    cat > "$d/NOTE" << 'LEOF'
INTERCEPTED DATA PACKETS
========================
Two encoded payloads captured from authenticated channel.
Only one is from the active session.
Identify the encoding scheme, decode the correct file.
LEOF
    # [UPGRADE UP-10] Hint no longer says "base64 encoding" directly
    meta "08" \
"Decode the file 'payload.dat' to find the password.\nA second encoded file exists — only one is authentic." \
"DECODE_ALPHA\n\nTwo payloads. One is real.\nNeither is plaintext — both are encoded.\nThe encoding leaves fingerprints in the character set and structure.\nIdentify it. Decode it. The right one is payload.dat." \
"Examine the file contents: what characters appear? Is there padding at the end?" \
"Different encoding schemes produce different character sets and structural patterns." \
"Once you identify the encoding, find the matching decode command. Apply it to the correct file."
}

# ── Level 09 — DECODE_BRAVO ───────────────────────────────────────────────────
# [UPGRADE UP-9] Added second signal file with different cipher
build_l09() {
    mkl "09" "$1"
    local d="$LEVELS_DIR/level09/challenge"
    echo "$1" | tr 'A-Za-z' 'N-ZA-Mn-za-m' > "$d/signal.dat"
    # [UPGRADE UP-9] Decoy: ROT13 of a fake password — looks authentic
    echo "$(gen_fake_pass ${#1})" | tr 'A-Za-z' 'N-ZA-Mn-za-m' > "$d/signal.dat.old"
    cat > "$d/NOTE" << 'LEOF'
INTERCEPTED SIGNALS — DECODED LAYER 1
=======================================
Two signal files recovered. One is current. One is stale.
Inner cipher layer remains on both.
The active signal is in signal.dat.
Reverse the cipher to extract the credential.
LEOF
    meta "09" \
"The file 'signal.dat' contains a ciphered message.\nDetermine the cipher from inspection and reverse it to get the password." \
"DECODE_BRAVO\n\nReadable characters. Meaningless words. A cipher.\nThis one is classic — letters shifted by a fixed amount.\nStudy the pattern. A becomes N. B becomes O.\nHow many positions? Which cipher is this?" \
"Look at signal.dat carefully. Map a few letters to see the shift pattern." \
"This cipher is symmetric — applying it twice returns the original. The tool that translates character sets is 'tr'." \
"Build the character mapping yourself. What does shifting each letter 13 positions look like in 'tr' syntax?"
}

# ── Level 10 — PHANTOM_SIGNAL ────────────────────────────────────────────────
# [UPGRADE UP-9] Multiple embedded strings; only one is between real markers
build_l10() {
    mkl "10" "$1"
    local d="$LEVELS_DIR/level10/challenge"
    {
        head -c 128 /dev/urandom 2>/dev/null
        # [UPGRADE UP-9] Fake key block to trap hasty players
        printf '\n===BEGIN_KEY===\n%s\n===END_KEY===\n' "$(gen_fake_pass ${#1})"
        head -c 128 /dev/urandom 2>/dev/null
        printf '\n===BEGIN_KEY===\n%s\n===END_KEY===\n' "$1"
        head -c 128 /dev/urandom 2>/dev/null
        # Another fake embedded string
        printf '\nKEY_CANDIDATE=%s\n' "$(gen_fake_pass ${#1})"
        head -c 128 /dev/urandom 2>/dev/null
    } > "$d/firmware.bin"
    cat > "$d/ANALYST_NOTE" << 'LEOF'
FIRMWARE IMAGE — BUILD 7731
============================
Binary blob extracted from device.
Multiple strings embedded during development.
Only one is the active credential.
Not every readable string is the answer.
Intel suggests the real one is the SECOND occurrence.
LEOF
    # [UPGRADE UP-10] Hint no longer names the markers
    meta "10" \
"Extract the plaintext credential embedded in binary file 'firmware.bin'.\nMultiple readable strings exist — only one is the active credential." \
"PHANTOM_SIGNAL\n\nA firmware image. Noise and signal.\nMultiple readable strings are embedded.\nThe development team left markers around the real one.\nNot every string you find is the answer." \
"What command extracts human-readable strings from a binary file?" \
"Use that command and examine all output carefully. Look for structured markers or patterns." \
"The active credential appears after a specific marker sequence. Find the pattern that surrounds the real one."
}

# ── Level 11 — THE_MAZE ───────────────────────────────────────────────────────
# Randomized placement; decoys scattered throughout
build_l11() {
    mkl "11" "$1"
    local d="$LEVELS_DIR/level11/challenge"
    local dirs=("alpha/x" "alpha/y" "alpha/z" "bravo/x" "bravo/y" "bravo/z"
                "charlie/x" "charlie/y" "charlie/z" "delta/x" "delta/y" "delta/z")
    local tgt_dir="${dirs[$((RANDOM % 12))]}"
    for dir in alpha bravo charlie delta; do
        for sub in x y z; do
            mkdir -p "$d/$dir/$sub"
            dd if=/dev/urandom bs=1 count=$((RANDOM%300+100)) \
               of="$d/$dir/$sub/datafile" 2>/dev/null
            [[ $(( RANDOM % 3 )) -eq 0 ]] && \
                echo "EXPIRED_$(gen_fake_pass 16)" > "$d/$dir/$sub/target.old"
            [[ $(( RANDOM % 4 )) -eq 0 ]] && \
                echo "INVALID_$(gen_fake_pass 16)" > "$d/$dir/$sub/target.bak"
            # [UPGRADE UP-9] Occasional 'target' file with wrong content as deep trap
            [[ $(( RANDOM % 6 )) -eq 0 && "$dir/$sub" != "$tgt_dir" ]] && \
                echo "$(gen_fake_pass ${#1})" > "$d/$dir/$sub/target"
        done
    done
    echo "$1" > "$d/$tgt_dir/target"
    meta "11" \
"A file named 'target' exists somewhere in the directory tree.\nDecoy files with identical or similar names also exist.\nFind and read the authentic one." \
"THE_MAZE\n\nDozens of directories. Hundreds of files.\nSome decoys use the exact same name.\nNot every 'target' is real.\nThe authentic file is in exactly one location — find it systematically." \
"How do you search an entire directory tree for files matching a specific name?" \
"There is a command for recursive file search. It supports filtering by exact name and file type." \
"Use exact name matching. If multiple results appear, cross-reference with what you know about the structure."
}

# ── Level 12 — DEEP_ARCHIVE ───────────────────────────────────────────────────
# [UPGRADE UP-9] Added decoy archive that decompresses to a fake password
build_l12() {
    mkl "12" "$1"
    local d="$LEVELS_DIR/level12/challenge"
    local tmp; tmp=$(mktemp -d)
    # Real archive — 3 layers
    echo "$1"             > "$tmp/core"
    gzip  -c "$tmp/core"  > "$tmp/l1"
    bzip2 -c "$tmp/l1"    > "$tmp/l2"
    gzip  -c "$tmp/l2"    > "$d/archive.gz"
    # [UPGRADE UP-9] Decoy archive — 2 layers, wrong content
    echo "$(gen_fake_pass ${#1})" > "$tmp/fake_core"
    gzip -c "$tmp/fake_core" > "$tmp/fake_l1"
    bzip2 -c "$tmp/fake_l1" > "$d/archive_backup.bz2"
    rm -rf "$tmp"
    cat > "$d/NOTE" << 'LEOF'
DATA ARCHIVES — ORIGIN UNKNOWN
================================
Two compressed artifacts recovered.
archive.gz is the primary target.
archive_backup.bz2 is a backup — contents may differ.
Determine extraction method from content.
LEOF
    meta "12" \
"Decompress archive.gz until you reach plaintext.\nMultiple archives exist — work only on archive.gz.\nUse 'file' after each step to identify the next format." \
"DEEP_ARCHIVE\n\nA compressed archive. How many layers?\nYou cannot know until you start peeling.\nA backup exists too — but it is not the target.\nfile is your compass. Use it after every step." \
"Work in /tmp to avoid cluttering the challenge directory. Start: cp archive.gz /tmp/ && cd /tmp" \
"Each decompression may produce a file needing a different tool. Rename with correct extension first." \
"Let file reveal each layer type. Do not guess the sequence. Rename, decompress, check, repeat."
}

# ── Level 13 — SETUID_HUNT ────────────────────────────────────────────────────
# [UPGRADE UP-9] Added SGID files as visual decoys (look similar to SUID in ls)
build_l13() {
    mkl "13" "$1"
    local d="$LEVELS_DIR/level13/challenge"
    local suid_target=$(( RANDOM % 9 + 1 ))
    local safe_perms=(644 755 640 600 750 444 555 664 700)
    for i in $(seq 1 9); do
        if [[ $i -eq $suid_target ]]; then
            echo "$1" > "$d/proc_$i"
            chmod 4755 "$d/proc_$i"
        else
            echo "process_binary_$i" > "$d/proc_$i"
            chmod "${safe_perms[$((RANDOM % ${#safe_perms[@]}))]}" "$d/proc_$i" 2>/dev/null \
                || chmod 644 "$d/proc_$i"
        fi
    done
    # [UPGRADE UP-9] SGID decoy — ls output shows 's' in group field, not owner
    # Hasty players mistake SGID for SUID; find -perm -4000 will NOT match it
    local sgid_decoy=$(( (suid_target % 9) + 1 ))
    [[ $sgid_decoy -eq $suid_target ]] && sgid_decoy=$(( sgid_decoy % 9 + 1 ))
    echo "$(gen_fake_pass ${#1})" > "$d/proc_${sgid_decoy}"
    chmod 2755 "$d/proc_${sgid_decoy}" 2>/dev/null || chmod 755 "$d/proc_${sgid_decoy}"
    cat > "$d/README" << 'LEOF'
POST-EXPLOITATION INTEL
========================
Shell access confirmed on target node.
Nine processes registered in the runtime directory.
One binary runs with elevated privileges.
Other files may appear privileged — verify the exact bit.

Privilege escalation begins with enumeration.
LEOF
    meta "13" \
"One of the nine proc files has the SUID bit set (owner execute = 's').\nOther files may look similar. Find the one with the correct privilege bit." \
"SETUID_HUNT\n\nNine binaries. One is elevated. One is a trap.\nBoth show 's' in ls output — but not in the same position.\nSUID runs as the file's owner. SGID runs as the file's group.\nOnly one of those is what you need." \
"SUID bit value is 4000. SGID bit value is 2000. They appear differently in ls -l output." \
"Use find with a permission filter. Make sure you filter for the SUID bit, not just any special bit." \
"The correct filter tests for owner execute position. Verify your find flag targets octal 4000 specifically."
}

# ── Level 14 — SIGNAL_DROP ────────────────────────────────────────────────────
build_l14() {
    mkl "14" "$1" "1"
    local d="$LEVELS_DIR/level14/challenge"
    cat > "$d/README" << 'LEOF'
NEXUS SIGNAL INTERCEPT
=======================
Active signal detected on the loopback interface.

Protocol  : TCP
Host      : localhost (127.0.0.1)
Port      : 4444

Connect and capture the transmission.
The credential is embedded in the packet.

Note: the server broadcasts for a limited number of connections.
LEOF
    meta "14" \
"Connect to localhost port 4444 and capture the transmitted credential.\nExtract only the credential value from the packet." \
"SIGNAL_DROP\n\nA signal broadcasts on the loopback.\nNo internet. No remote server.\nEverything you need is on this machine.\nKnow how to reach it." \
"What tool connects to a TCP port and reads the response?" \
"netcat is the standard tool. Bash also has a built-in TCP mechanism via /dev/tcp." \
"The packet contains more than just the credential. Parse the output carefully."
}

# ── Level 15 — DEAD_DROP ──────────────────────────────────────────────────────
# [UPGRADE UP-9] More hidden files; added a .vault dir with another fake
build_l15() {
    mkl "15" "$1"
    local d="$LEVELS_DIR/level15/challenge"
    mkdir -p "$d/.ssh" "$d/.config" "$d/.cache" "$d/.vault"
    echo -e '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAFAKEDATA\nTRUNCATED\n-----END RSA PRIVATE KEY-----' \
        > "$d/.ssh/id_rsa"
    echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... operative@nexus' > "$d/.ssh/id_rsa.pub"
    printf 'Host nexus-*\n  User operative\n  IdentityFile ~/.ssh/id_rsa\n' > "$d/.ssh/config"
    echo "$1"                              > "$d/.ssh/credentials"
    chmod 600 "$d/.ssh/credentials"
    echo "STALE_$(gen_fake_pass 16)"       > "$d/.ssh/credentials.old"
    echo "$(gen_fake_pass ${#1})"          > "$d/.ssh/id_rsa_pass"
    printf '[prefs]\ntheme=dark\nlog=verbose\nalert=true\n' > "$d/.config/settings"
    printf 'last_sync=1709823600\nnode_id=nx-7731\n' > "$d/.cache/state"
    # [UPGRADE UP-9] .vault decoy with lookalike password
    echo "$(gen_fake_pass ${#1})"          > "$d/.vault/access_key"
    chmod 600 "$d/.vault/access_key"
    cat > "$d/README" << 'LEOF'
FIELD OPERATIVE DEAD DROP
==========================
Credentials were cached at this location by a field agent.
Multiple hidden directories. Multiple files.
Standard enumeration applies.
Not everything here is current or valid.
Exactly one file contains a valid active credential.
LEOF
    meta "15" \
"Credentials are stored across multiple hidden directories.\nEnumerate all hidden files and directories to find the one valid access code." \
"DEAD_DROP\n\nMultiple hidden directories. Multiple files.\nSome are decoys. Some are expired. One is live.\nYou must look everywhere before you can know.\nEnumerate systematically — not randomly." \
"How do you reveal hidden directories and their contents in a single directory listing?" \
"Explore each hidden directory individually. Multiple hidden dirs exist at different depths." \
"A valid credential has a specific format and length. Read each file — the authentic one will stand out."
}

# ── Level 16 — CRONTAB ────────────────────────────────────────────────────────
# [UPGRADE UP-9] Third decoy credential that looks more like a real token
build_l16() {
    mkl "16" "$1"
    local d="$LEVELS_DIR/level16/challenge"
    local decoy1; decoy1=$(gen_fake_pass 20)
    local decoy2; decoy2=$(gen_fake_pass 18)
    local decoy3; decoy3=$(gen_fake_pass 22)
    mkdir -p "$d/cron.d"
    cat > "$d/cron.d/backup.sh" << CEOF
#!/bin/bash
# Backup job — 02:00 daily
BACKUP_DIR="/var/backups/nexus"
S3_ENDPOINT="s3://nexus-backup-prod"
S3_ACCESS="AKIAIOSFODNN7EXAMPLE"
S3_SECRET="$decoy1"
tar -czf "/tmp/backup_\$(date +%Y%m%d).tar.gz" /opt/nexus/ 2>/dev/null
CEOF
    cat > "$d/cron.d/cleanup.sh" << 'CEOF'
#!/bin/bash
# Log cleanup — weekly (Sunday 04:00)
find /var/log/nexus -name "*.log" -mtime +30 -delete 2>/dev/null
find /tmp -name "backup_*" -mtime +7 -delete 2>/dev/null
CEOF
    cat > "$d/cron.d/healthcheck.sh" << CEOF
#!/bin/bash
# Health check — every 5min
DB_HOST="db-primary.nexus.internal"
DB_PORT=5432
DB_PASS="$decoy2"
NX_MONITOR_KEY="$decoy3"
pg_isready -h "\$DB_HOST" -p "\$DB_PORT" 2>/dev/null && echo "DB:UP" || echo "DB:DOWN"
CEOF
    cat > "$d/cron.d/collector.sh" << CEOF
#!/bin/bash
# Data collector — every 15min
NX_CONN_TOKEN="$1"
curl -sf -H "X-Auth: \$NX_CONN_TOKEN" "https://nexus-core.internal/api/collect" 2>/dev/null
CEOF
    chmod +x "$d/cron.d/"*.sh
    cat > "$d/crontab" << 'CEOF'
# NEXUS System Crontab
0 2 * * *    /opt/nexus/cron.d/backup.sh
0 4 * * 0    /opt/nexus/cron.d/cleanup.sh
*/5 * * * *  /opt/nexus/cron.d/healthcheck.sh
*/15 * * * * /opt/nexus/cron.d/collector.sh
CEOF
    # [UPGRADE UP-10] Hint no longer names NX_CONN_TOKEN directly
    meta "16" \
"A live credential is hardcoded in one of the scripts in cron.d/.\nFour scripts contain credential-looking values. Only one is active." \
"CRONTAB\n\nFour scripts. Multiple credentials.\nMost are infrastructure secrets — not what you need.\nThe active token has a specific naming convention and purpose.\nSearch all scripts. Then determine which value is the live access token." \
"How do you search for patterns across multiple files in a directory recursively?" \
"grep -r searches all files. Look for variable names containing TOKEN, KEY, or similar patterns." \
"Compare the variable names and context. The active one is used for outbound authentication — not storage or monitoring."
}

# ── Level 17 — ENV_LEAK ───────────────────────────────────────────────────────
build_l17() {
    mkl "17" "$1" "1"
    local d="$LEVELS_DIR/level17/challenge"
    cat > "$d/README" << 'LEOF'
PROCESS ENVIRONMENT LEAK
=========================
A privileged process is active on this system.
Its runtime configuration leaked into the shell environment.

Enumerate the environment.
Find the credential among the configuration values.
Not all values are credentials — identify the one that is.
LEOF
    cat > "$d/app.py" << 'LEOF'
#!/usr/bin/env python3
# NEXUS Data Collector v0.4
import os
nexus_cfg = {k: v for k, v in os.environ.items() if k.startswith('NEXUS_')}
print(f"[+] Loaded {len(nexus_cfg)} NEXUS runtime parameters")
LEOF
    meta "17" \
"A credential has leaked into the shell environment variables.\nEnumerate all NEXUS_* variables and identify which one is the actual access token." \
"ENV_LEAK\n\nThe process left its secrets in open air.\nMany configuration values. Only one is a credential.\nConfig values look like settings. Credentials look like random strings.\nEnumerate. Distinguish. Submit the right one." \
"What command lists environment variables? What can you use to filter by prefix?" \
"env or printenv will list all variables. Pipe through grep to filter by naming convention." \
"Configuration values follow predictable patterns. A token looks different — examine each NEXUS_* value carefully."
}

# ── Level 18 — WEB_OF_LIES ────────────────────────────────────────────────────
# [UPGRADE UP-9] Two ASCII text files — one is JSON (parseable), one is the credential
build_l18() {
    mkl "18" "$1"
    local d="$LEVELS_DIR/level18/challenge"
    echo "$1"                                      > "$d/report_final.exe"
    head -c $(( RANDOM % 200 + 100 )) /dev/urandom > "$d/config.txt"
    head -c $(( RANDOM % 200 + 100 )) /dev/urandom > "$d/readme.md"
    # [UPGRADE UP-9] JSON file also reports as ASCII text but is clearly not a password
    printf '{"status":"ok","build":"7731","checksum":"d41d8cd9f00b204e9800998ecf8427e","ts":1709823600}' \
        > "$d/manifest.json"
    printf '\x7fELF\x02\x01\x01'                  > "$d/launcher.sh"
    head -c $(( RANDOM % 150 + 100 )) /dev/urandom >> "$d/launcher.sh"
    head -c $(( RANDOM % 180 + 80  )) /dev/urandom > "$d/data.bin"
    cat > "$d/INCIDENT_REPORT" << 'LEOF'
INCIDENT REPORT — FILE ANALYSIS REQUIRED
==========================================
Six files recovered from compromised endpoint.
File extensions have been modified post-exfiltration.
Extensions are unreliable. Content must be verified directly.
A recoverable credential exists in one file.
Not every readable file is a credential.
LEOF
    meta "18" \
"Six files with potentially misleading extensions.\nOne contains a raw credential. Identify it without trusting filenames or extensions." \
"WEB_OF_LIES\n\nExtensions lie. Names lie.\nSome files are readable but still not credentials.\nYou need the one that IS the access code — not just any readable file.\nThe tool that reads file signatures is only your first step." \
"What command identifies file types based on internal content rather than extension?" \
"Use it on all files. Multiple files may appear readable — distinguish credential from structured data." \
"A credential is a raw string. Structured data has syntax. The difference is visible when you cat each readable file."
}

# ── Level 19 — HEX_GHOST ─────────────────────────────────────────────────────
# [UPGRADE UP-9] Multiple encoded strings; only one decodes to a valid password
build_l19() {
    mkl "19" "$1"
    local d="$LEVELS_DIR/level19/challenge"
    local encoded; encoded=$(echo -n "$1" | base64 | tr -d '\n')
    # [UPGRADE UP-9] Fakes use pure random bytes — decode to ~3-4 alphanum chars
    # after tr -dc A-Za-z0-9, clearly too short to be a valid password (14-28 chars)
    local fake1; fake1=$(head -c 16 /dev/urandom 2>/dev/null | base64 | tr -d '\n')
    local fake2; fake2=$(head -c 16 /dev/urandom 2>/dev/null | base64 | tr -d '\n')
    {
        head -c 192 /dev/urandom 2>/dev/null
        # First fake — between FEED/FACE markers, decodes to binary garbage
        printf '\xFE\xED\xFA\xCE'
        printf '%s' "$fake1"
        printf '\xFE\xED\xFA\xCE'
        head -c 192 /dev/urandom 2>/dev/null
        # Real credential — between DEAD/CAFE markers (primary session markers)
        printf '\xDE\xAD\xBE\xEF'
        printf '%s' "$encoded"
        printf '\xCA\xFE\xBA\xBE'
        head -c 192 /dev/urandom 2>/dev/null
        # Second fake — between BAAD/F00D markers, also decodes to binary garbage
        printf '\xBA\xAD\xF0\x0D'
        printf '%s' "$fake2"
        printf '\xBA\xAD\xF0\x0D'
        head -c 192 /dev/urandom 2>/dev/null
    } > "$d/memdump.bin"
    cat > "$d/NOTE" << 'LEOF'
MEMORY DUMP — NEXUS CORE PROCESS (PID 1337)
Captured: 03:17:44 UTC

Analyst notes:
  Multiple credential artifacts present in this snapshot.
  Only one is active. The others are stale session tokens.
  The active credential is bounded by the primary memory markers.
  Locate it. Decode it. That is the access code.
LEOF
    meta "19" \
"A credential is embedded in binary 'memdump.bin'.\nMultiple encoded strings exist — only one is the active credential.\nExtract the correct one and decode it." \
"HEX_GHOST\n\nMemory holds many secrets.\nMultiple encoded strings. Multiple sets of markers.\nOnly one set of markers indicates the primary active session.\nExtract. Identify. Decode. Not every result is correct." \
"'strings' extracts printable text from binary files. Multiple results may look like encoded data." \
"Each encoded artifact is bounded by different memory markers. Identify the correct pair of markers." \
"Decode each candidate. A valid credential has a specific length and character set. Only one will be correct."
}

# ── Level 20 — PIPELINE ───────────────────────────────────────────────────────
# [UPGRADE UP-9] Added second admin-role entry with wrong (non-base64) token
build_l20() {
    mkl "20" "$1"
    local d="$LEVELS_DIR/level20/challenge"
    local encoded; encoded=$(echo -n "$1" | base64 | tr -d '\n')
    # [UPGRADE UP-9] Fake admin with a non-base64 token — decodes to garbage
    local fake_tok; fake_tok=$(gen_fake_pass 20)
    {
        for i in $(seq 1 20); do
            local roles=("analyst" "observer" "auditor" "monitor" "reporter")
            local role="${roles[$((RANDOM % 5))]}"
            local tok; tok=$(head -c 12 /dev/urandom 2>/dev/null | base64 | tr -d '=\n' | head -c 16)
            printf 'USER:agent_%03d|ROLE:%s|ACCESS:LEVEL_%d|TOKEN:%s|STATUS:inactive\n' \
                "$i" "$role" "$(( RANDOM % 3 + 1 ))" "$tok"
        done
        # [UPGRADE UP-9] Fake admin — wrong token, STATUS:suspended
        printf 'USER:ghost_admin|ROLE:admin|ACCESS:LEVEL_5|TOKEN:%s|STATUS:suspended\n' "$fake_tok"
        for i in $(seq 21 40); do
            local roles=("analyst" "observer" "auditor" "monitor" "reporter")
            local role="${roles[$((RANDOM % 5))]}"
            local tok; tok=$(head -c 12 /dev/urandom 2>/dev/null | base64 | tr -d '=\n' | head -c 16)
            printf 'USER:agent_%03d|ROLE:%s|ACCESS:LEVEL_%d|TOKEN:%s|STATUS:inactive\n' \
                "$i" "$role" "$(( RANDOM % 3 + 1 ))" "$tok"
        done
        # Real admin — STATUS:active distinguishes it
        printf 'USER:shadow_root|ROLE:admin|ACCESS:LEVEL_5|TOKEN:%s|STATUS:active\n' "$encoded"
    } | _shuffle_lines > "$d/personnel.db"
    cat > "$d/README" << 'LEOF'
NEXUS OPERATIVE REGISTRY — PERSONNEL DATABASE
Format: USER:<id>|ROLE:<role>|ACCESS:<level>|TOKEN:<value>|STATUS:<state>

42 operative records. Two accounts have administrator role.
Only one is active. The other is suspended.
The active administrator's token is encoded.
Your access code is the decoded token value.

Build the extraction pipeline.
LEOF
    meta "20" \
"Extract the ACTIVE admin's encoded TOKEN from personnel.db and decode it.\nTwo admin entries exist — only one is active. Build a pipeline to extract and decode the correct one." \
"PIPELINE\n\nForty-two records. Two admins. One active. One suspended.\nRaw data tells you nothing until you shape it.\nEach pipe stage cuts closer to truth.\nFilter. Narrow. Extract. Decode. In the right order." \
"You need to filter by role, then by status, then extract the TOKEN field, then decode the value." \
"Multiple pipe stages: grep can filter twice. Field extraction uses cut or grep -o. base64 handles decoding." \
"Chain your commands. If you get two results from grep, add another filter. The STATUS field distinguishes the real one."
}

# =============================================================================
# NETWORK SERVER — CROSS-PLATFORM (Level 14)
# [UPGRADE UP-8] Replaced non-portable nc flags with universally compatible ones
# =============================================================================

_NC_MODE=""

_detect_nc_mode() {
    [[ -n "$_NC_MODE" ]] && return
    if command -v nc >/dev/null 2>&1; then
        local h; h=$(nc --help 2>&1; nc -h 2>&1; true)
        # [UPGRADE UP-8] Detect mode without relying on -lvnp/-q flags
        if echo "$h" | grep -q '\-q '; then
            _NC_MODE="gnu"
        elif echo "$h" | grep -q 'OpenBSD\|BSD'; then
            _NC_MODE="bsd"
        else
            _NC_MODE="bsd"   # Safe fallback — most minimal nc variants accept -l PORT
        fi
    elif command -v ncat >/dev/null 2>&1; then
        _NC_MODE="ncat"
    else
        _NC_MODE="none"
    fi
}

_nc_serve_once() {
    local port="$1" msg="$2"
    # [UPGRADE UP-8] Universally compatible nc invocations
    # GNU nc:    nc -l -p PORT      (no -v/-n/-q in minimal installs)
    # BSD nc:    nc -l PORT         (OpenBSD-style, Termux)
    # ncat:      ncat -l PORT       (nmap's nc replacement)
    case "$_NC_MODE" in
        gnu)  printf '%s\n' "$msg" | nc   -l -p "$port"         2>/dev/null; return 0 ;;
        bsd)  printf '%s\n' "$msg" | nc   -l    "$port"         2>/dev/null; return 0 ;;
        ncat) printf '%s\n' "$msg" | ncat -l    "$port" --send-only 2>/dev/null; return 0 ;;
        none) return 1 ;;
    esac
}

_start_level_server() {
    local lvl="$1"
    [[ "$lvl" != "14" ]] && return 0
    _detect_nc_mode
    if [[ "$_NC_MODE" == "none" ]]; then
        pw "nc/ncat not found — Level 14 requires netcat"
        pw "Install: apt install netcat   (Termux: pkg install netcat)"
        return 1
    fi
    # [UPGRADE UP-3] Read plain from CORE_DIR
    local plain; plain=$(_read_core "$CORE_DIR/14.plain")
    [[ -z "$plain" ]] && plain="SETUP_ERROR"
    rm -f "$GAME_DIR/.server_pid"
    ( for _ in 1 2 3 4 5 6 7 8 9 10 12 14 16 18 20; do
          _nc_serve_once "$NET_PORT" "NEXUS_PACKET:${plain}"
          sleep 0.3
      done ) &
    echo $! > "$GAME_DIR/.server_pid"
}

_stop_level_server() {
    [[ -f "$GAME_DIR/.server_pid" ]] || return
    local pid; pid=$(cat "$GAME_DIR/.server_pid" 2>/dev/null)
    kill "$pid" 2>/dev/null || true
    rm -f "$GAME_DIR/.server_pid"
}

# =============================================================================
# GAME SHELL — TIME AUTHORITY + PERSISTENT HINTS + SANDBOX + LOGGING
# =============================================================================

launch_shell() {
    local lvl="$1"
    local ldir="$LEVELS_DIR/level$lvl"
    local cdir="$ldir/challenge"
    local cost; cost=$(hint_cost "$lvl")
    local limit; limit=$(level_time_limit "$lvl")

    _start_level_server "$lvl"

    # Restore saved hint count for this level
    local saved_hint_var="HINTS_L${lvl}"
    local saved_hints="${!saved_hint_var:-0}"
    : > "$SAVE_DIR/.hints"
    for (( h=0; h<saved_hints; h++ )); do echo "1" >> "$SAVE_DIR/.hints"; done

    # ── .gi: expanded heredoc (runtime values written at launch time) ──────────
    local p17=""
    [[ "$lvl" == "17" ]] && p17=$(_read_core "$CORE_DIR/17.plain")
    local timed_val="${TIMED_MODE:-0}"

    cat > "$GAME_DIR/.gi" << GIEOF
_NX_DIR="$GAME_DIR"
_NX_LVL="$lvl"
_NX_TIMED="$timed_val"
_NX_LIMIT=$limit
_NX_START=\$(date +%s)
_NX_COST=$cost
_NX_JAIL="$cdir"
_NX_CORE="$GAME_DIR/.core"
_NX_LOG="$GAME_DIR/logs/.cmdlog"
GIEOF

    # Level 17: inject environment variables
    if [[ "$lvl" == "17" && -n "$p17" ]]; then
        cat >> "$GAME_DIR/.gi" << ENVEOF
export NEXUS_SESSION_TOKEN="$p17"
export NEXUS_DB_PASSWORD="db_prod_nexus_2024!"
export NEXUS_DB_HOST="db-primary.nexus.internal"
export NEXUS_DB_PORT="5432"
export NEXUS_ENV="production"
export NEXUS_LOG_LEVEL="warn"
export NEXUS_PORT="8443"
export NEXUS_VERSION="4.7.2"
export NEXUS_REGION="eu-west-1"
export NEXUS_INSTANCE_ID="i-0f7b3c2a1d9e8f4b6"
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
ENVEOF
    fi

    # ── .gf: single-quoted heredoc — static game functions, NO expansion ───────
    cat > "$GAME_DIR/.gf" << 'GFEOF'
source "$HOME/.nexus/.gi" 2>/dev/null || true

_LD="$_NX_DIR/levels/level$_NX_LVL"

# [UPGRADE UP-4] Internal core file reader — same temp-unlock logic as outer shell
_read_core_shell() {
    local file="$1"
    [[ ! -e "$file" ]] && return 1
    chmod 400 "$file" 2>/dev/null
    local c; c=$(cat "$file" 2>/dev/null)
    chmod 000 "$file" 2>/dev/null
    printf '%s' "$c"
}

# [UPGRADE UP-7] PASSIVE CHEAT LOGGING — DEBUG trap records all commands
# Does NOT block anything — purely observational
# Filters out internal/system commands to keep log readable
mkdir -p "$(dirname "$_NX_LOG")" 2>/dev/null
trap '
    case "$BASH_COMMAND" in
        _*|source*|true|false|:|\[*|local*|printf*|echo*) ;;
        *) printf "[%s] LVL:%s  %s\n" "$(date +%H:%M:%S)" "$_NX_LVL" "$BASH_COMMAND" \
               >> "$_NX_LOG" 2>/dev/null ;;
    esac
' DEBUG

# [UPGRADE UP-6] SOFT SANDBOXING — override cd to restrict navigation
# Allows movement within challenge dir and /tmp (needed for L12 decompression)
# Redirects with a message if player tries to leave the challenge scope
cd() {
    local target="${1:-.}"
    local new_dir
    # Resolve the target path using a subshell to get absolute form
    new_dir=$(builtin cd "$target" 2>/dev/null && pwd)
    if [[ -z "$new_dir" ]]; then
        echo -e "\033[1;31m[NEXUS] Directory not found: $target\033[0m" >&2
        return 1
    fi
    case "$new_dir" in
        "$_NX_JAIL"|"$_NX_JAIL"/*)
            # Within challenge directory — always allowed
            builtin cd "$new_dir" ;;
        /tmp|/tmp/*)
            # /tmp allowed for decompression tasks (L12 etc.)
            builtin cd "$new_dir" ;;
        *)
            # Outside scope — soft block with informative message
            echo -e "\033[1;33m[NEXUS] Navigation outside the challenge scope is restricted.\033[0m"
            echo -e "\033[2m  Challenge dir: $_NX_JAIL\033[0m"
            echo -e "\033[2m  /tmp is also available for temporary work.\033[0m"
            return 1 ;;
    esac
}

# ── Timer system ──────────────────────────────────────────────────────────────
if [[ "$_NX_TIMED" == "1" ]]; then

    _update_timer() {
        local _now _left _m _s
        _now=$(date +%s)
        _left=$(( _NX_LIMIT - (_now - _NX_START) ))
        [[ $_left -lt 0 ]] && _left=0
        _m=$(( _left / 60 ))
        _s=$(( _left % 60 ))

        if [[ $_left -le 0 ]]; then
            printf '\n\033[1;31m╔══════════════════════════════════════════╗\n'
            printf   '║  ⛔  NEXUS: TIME EXPIRED — ACCESS DENIED  ║\n'
            printf   '╚══════════════════════════════════════════╝\033[0m\n'
            echo "TIMEOUT" > "$_NX_DIR/save/.timeout"
            exit 1
        elif [[ $_left -le 10 ]]; then
            PS1="\[\033[1;31m\]\[\033[5m\][⚠ FINAL ${_left}s !!!]\[\033[0m\]\[\033[1;31m\] \w\[\033[0m\]\$ "
        elif [[ $_left -le 60 ]]; then
            PS1="\[\033[1;31m\][NEXUS:LVL-${_NX_LVL}][⚠$(printf '%d:%02d' $_m $_s)]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ "
        else
            PS1="\[\033[1;31m\][NEXUS:LVL-${_NX_LVL}][⏱$(printf '%d:%02d' $_m $_s)]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ "
        fi
    }

    PROMPT_COMMAND='_update_timer'

    _MY_PID=$$
    (
        while kill -0 "$_MY_PID" 2>/dev/null; do
            _tick_now=$(date +%s)
            _tick_left=$(( _NX_LIMIT - (_tick_now - _NX_START) ))
            if [[ $_tick_left -le 30 ]]; then sleep 1
            else                              sleep 5; fi
            kill -WINCH "$_MY_PID" 2>/dev/null
        done
    ) &
    _TICK_PID=$!
    trap "kill '$_TICK_PID' 2>/dev/null; trap - EXIT" EXIT

else
    PS1='\[\033[1;31m\][NEXUS:\[\033[1;33m\]LVL-'"$_NX_LVL"'\[\033[1;31m\]]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ '
fi

# ── Game functions ────────────────────────────────────────────────────────────
objective() {
    echo -e "\n\033[1;36m╔══════════════════════════════════╗"
    echo    "║       MISSION OBJECTIVE          ║"
    echo -e "╚══════════════════════════════════╝\033[0m"
    cat "$_LD/objective" 2>/dev/null; echo ""
}

story() { echo -e "\n\033[1;35m$(cat "$_LD/narrative" 2>/dev/null)\033[0m\n"; }

hint() {
    local pf="$_LD/hint_pos"
    local pos; pos=$(cat "$pf" 2>/dev/null || echo 0)
    local hints=()
    while IFS= read -r line; do hints+=("$line"); done < "$_LD/hints"
    local total=${#hints[@]}
    if [[ $pos -lt $total ]]; then
        echo -e "\n\033[1;33m[HINT $((pos+1))/$total — costs ${_NX_COST} pts]\033[0m ${hints[$pos]}\n"
        echo $(( pos + 1 )) > "$pf"
        echo "1" >> "$_NX_DIR/save/.hints"
    else
        echo -e "\n\033[1;33m[!] No more hints available.\033[0m\n"
    fi
}

submit() {
    [[ -z "${1:-}" ]] && { echo -e "\033[1;31mUsage: submit <password>\033[0m"; return 1; }

    # [TIME AUTHORITY] Validate epoch time at submission — independent of display
    if [[ "$_NX_TIMED" == "1" ]]; then
        local _sub_now; _sub_now=$(date +%s)
        local _sub_elapsed=$(( _sub_now - _NX_START ))
        if [[ $_sub_elapsed -ge $_NX_LIMIT ]]; then
            echo -e "\n\033[1;31m╔══════════════════════════════════════════╗"
            echo    "║  ⛔  ACCESS DENIED: TIME EXPIRED          ║"
            echo    "║  Submissions are rejected after timeout.  ║"
            echo -e "╚══════════════════════════════════════════╝\033[0m"
            echo "TIMEOUT" > "$_NX_DIR/save/.timeout"
            exit 1
        fi
    fi

    # [UPGRADE UP-3/UP-4] Read hash from CORE_DIR with temporary unlock
    local stored; stored=$(_read_core_shell "$_NX_CORE/$_NX_LVL.hash")
    local given;  given=$(echo -n "$1" | sha256sum | awk '{print $1}')
    local att; att=$(cat "$_LD/.attempts" 2>/dev/null || echo 0)
    att=$(( att + 1 ))
    echo "$att" > "$_LD/.attempts"

    if [[ "$given" == "$stored" ]]; then
        echo -e "\n\033[1;32m  ╔═══════════════════════════════╗"
        echo    "  ║   ✓  ACCESS GRANTED           ║"
        printf  "  ║   Attempts: %-17s║\n" "$att"
        echo -e "  ╚═══════════════════════════════╝\033[0m"
        echo "$_NX_LVL" > "$_NX_DIR/save/.done"
        exit 0
    else
        echo -e "\n\033[1;31m[✗] Incorrect. Attempt #${att}.\033[0m"
        if   [[ ${#1} -lt 14 ]];     then echo -e "\033[2m  Tip: The password is longer than that.\033[0m"
        elif [[ ${#1} -gt 30 ]];     then echo -e "\033[2m  Tip: May have extra characters — trim your output.\033[0m"
        elif [[ "$1" == *" "* ]];    then echo -e "\033[2m  Tip: Remove spaces — submit the raw value only.\033[0m"
        elif [[ $att -ge 3 ]];       then echo -e "\033[2m  Tip: Use 'hint' if you are stuck.\033[0m"
        fi; echo ""
    fi
}

score() {
    # [UPGRADE UP-5] Use safe parser instead of source inside game shell too
    local _sc_lvl _sc_score _sc_ach
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        case "$k" in
            LEVEL) _sc_lvl="$v" ;;
            SCORE) _sc_score="$v" ;;
        esac
    done < "$_NX_DIR/save/state" 2>/dev/null
    local h; h=$(wc -l < "$_NX_DIR/save/.hints" 2>/dev/null || echo 0)
    echo -e "\n\033[1;37m  Score  : \033[1;32m${_sc_score:-0} pts"
    echo -e "\033[1;37m  Level  : \033[1;33m${_sc_lvl:-01} / 20"
    echo -e "\033[1;37m  Hints  : \033[1;31m${h} used this level\033[0m\n"
}

achievements() {
    local _ac_ach=""
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        [[ "$k" == "ACHIEVEMENTS" ]] && _ac_ach="$v"
    done < "$_NX_DIR/save/state" 2>/dev/null
    echo -e "\n\033[1;35m══ ACHIEVEMENTS ══\033[0m"
    if [[ -z "${_ac_ach:-}" ]]; then echo " None yet."; echo ""; return; fi
    echo "$_ac_ach" | tr '|' '\n' | grep ':' | cut -d: -f2- | \
        while IFS= read -r a; do echo -e " 🏆  $a"; done
    echo ""
}

nexus_help() {
    echo -e "\n\033[1;36m╔═ NEXUS COMMANDS ═══════════════════════════╗\033[0m"
    echo "  objective    — mission brief"
    echo "  story        — narrative / lore"
    echo "  hint         — next hint (scaled cost per level)"
    echo "  submit <pw>  — submit answer (time validated at this point)"
    echo "  score        — current points and level"
    echo "  achievements — unlocked medals"
    echo "  nexus_help   — this menu"
    echo "  exit         — return to NEXUS main menu"
    echo -e "\033[2m  All normal bash commands work here.\033[0m\n"
}

# ── Startup display ───────────────────────────────────────────────────────────
clear
echo -e "\033[1;31m  ╔════════════════════════════════════════════╗"
printf  "  ║  NEXUS TERMINAL — LEVEL %s / 20            ║\n" "$_NX_LVL"
if [[ "$_NX_TIMED" == "1" ]]; then
    _m=$(( _NX_LIMIT / 60 ))
    printf  "  ║  ⏱ TIMED — %d:00 budget | time enforced    ║\n" "$_m"
fi
echo -e "  ╚════════════════════════════════════════════╝\033[0m"
story
objective
echo -e "\033[2mType 'nexus_help' for commands. 'hint' if stuck.\033[0m\n"
GFEOF

    # Write rcfile and clear signal files
    local rc; rc=$(mktemp)
    cat > "$rc" << RCEOF
source "$GAME_DIR/.gi" 2>/dev/null || true
source "$GAME_DIR/.gf" 2>/dev/null || true
cd "$cdir" 2>/dev/null || true
RCEOF
    rm -f "$SAVE_DIR/.done" "$SAVE_DIR/.timeout"

    bash --rcfile "$rc" -i
    rm -f "$rc"
    _stop_level_server

    # Persist hint count back to state regardless of outcome
    local final_hints; final_hints=$(wc -l < "$SAVE_DIR/.hints" 2>/dev/null || echo 0)
    eval "HINTS_L${lvl}=$final_hints"
    save_state

    if [[ -f "$SAVE_DIR/.timeout" ]]; then
        rm -f "$SAVE_DIR/.timeout"
        SCORE=$(( SCORE - 50 ))
        [[ $SCORE -lt 0 ]] && SCORE=0
        save_state
        echo -e "\n${R}[!] Timed out. -50 pts. Score: ${SCORE}${N}\n"
        sleep 2; return 1
    fi

    if [[ -f "$SAVE_DIR/.done" ]]; then
        local done_lvl; done_lvl=$(cat "$SAVE_DIR/.done")
        rm -f "$SAVE_DIR/.done"
        [[ "$done_lvl" == "$lvl" ]] && { _complete_level "$lvl"; return 0; }
    fi
    return 1
}

# =============================================================================
# LEVEL COMPLETION
# =============================================================================

_complete_level() {
    local lvl="$1"
    local hints; hints=$(wc -l < "$SAVE_DIR/.hints" 2>/dev/null || echo 0)
    local cost; cost=$(hint_cost "$lvl")
    local deduction=$(( hints * cost ))
    local earned=$(( 100 - deduction ))
    [[ $earned -lt 10 ]] && earned=10
    SCORE=$(( SCORE + earned ))

    # Advance LEVEL before achievements — save records correct next level
    local next=$(( 10#$lvl + 1 ))
    LEVEL=$(printf "%02d" $next)

    case "$lvl" in
        "01") give_achievement "FIRST_BLOOD"       "First Blood — Level 1 cleared" ;;
        "05") give_achievement "FILE_READER"        "File Whisperer — Mastered file typing" ;;
        "08") give_achievement "DECODER"            "Decoder Ring — Cracked base64" ;;
        "10") give_achievement "GHOST_HUNTER"       "Ghost Hunter — Extracted binary secrets" ;;
        "11") give_achievement "MAZE_RUNNER"        "Maze Runner — Mastered find" ;;
        "13") give_achievement "SUID_FINDER"        "SUID Hunter — Post-exploitation enum" ;;
        "14") give_achievement "SIGNAL_INTERCEPTED" "Signal Intercepted — Netcat mastery" ;;
        "17") give_achievement "ENV_AGENT"          "Env Agent — Credential exposure found" ;;
        "19") give_achievement "HEX_ALCHEMIST"      "Hex Alchemist — Binary + Decode chained" ;;
        "20") give_achievement "PIPE_MASTER"        "Pipe Master — Multi-stage pipeline" ;;
    esac
    [[ "$hints" -eq 0 ]] && give_achievement "PURE_${lvl}" "Pure LVL${lvl} — Zero hints used"

    if [[ $next -gt $TOTAL_LEVELS ]]; then
        COMPLETED=1
        give_achievement "THE_ARCHITECT" "The Architect — All 20 levels cleared"
        if [[ "$SPEEDRUN" == "1" && -n "$SR_START" ]]; then
            local elapsed=$(( $(date +%s) - SR_START ))
            local mins=$(( elapsed / 60 ))
            if [[ -z "$SR_BEST" || $elapsed -lt $SR_BEST ]]; then
                SR_BEST=$elapsed
                if   [[ $mins -lt 20 ]]; then give_achievement "SR_GOLD"   "Speedrun GOLD — Under 20 min"
                elif [[ $mins -lt 40 ]]; then give_achievement "SR_SILVER" "Speedrun SILVER — Under 40 min"
                else                          give_achievement "SR_BRONZE" "Speedrun BRONZE — Completed"
                fi
                pg "Speedrun record: ${mins}m $(( elapsed % 60 ))s"
            fi
        fi
    fi

    save_state
    echo -e "\n${G}[+] Level cleared! +${earned} pts  (hints: $hints × ${cost}pts)${N}"
    sleep 1
}

# =============================================================================
# COMMANDS
# =============================================================================

# SIGINT trap — clean rollback if setup is interrupted
_setup_abort() {
    echo ""
    pe "Setup interrupted — rolling back partial state..."
    if [[ -n "$GAME_DIR" && "$GAME_DIR" == "$HOME/.nexus" ]]; then
        rm -rf "$GAME_DIR"
    fi
    exit 1
}

cmd_setup() {
    trap '_setup_abort' INT TERM
    banner
    pi "Initializing NEXUS v${VERSION}..."

    local missing=()
    for dep in sha256sum base64 gzip bzip2 awk; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && {
        pw "Missing: ${missing[*]}"
        pw "Install: apt install coreutils bzip2 gawk"
    }
    command -v nc      &>/dev/null || pw "nc not found (L14) — apt install netcat / pkg install netcat"
    command -v xxd     &>/dev/null || pw "xxd optional (L19) — apt install xxd"
    command -v strings &>/dev/null || pw "strings optional (L10/L19) — apt install binutils"

    # GAME_DIR safety guard — never rm -rf on unverified path
    if [[ -z "$GAME_DIR" || "$GAME_DIR" != "$HOME/.nexus" ]]; then
        pe "GAME_DIR safety check failed: '${GAME_DIR}' — aborting"
        exit 1
    fi

    rm -rf "$GAME_DIR"
    mkdir -p "$LEVELS_DIR" "$SAVE_DIR" "$CORE_DIR"

    # [UPGRADE UP-12] Create log directory with restricted permissions
    mkdir -p "$GAME_DIR/logs"
    chmod 700 "$GAME_DIR/logs"
    touch "$GAME_DIR/logs/.cmdlog"
    chmod 600 "$GAME_DIR/logs/.cmdlog"

    LEVEL="01"; SCORE=0; ACHIEVEMENTS=""; SPEEDRUN=0
    SR_START=""; SR_BEST=""; COMPLETED=0
    _init_hint_vars
    save_state
    : > "$SAVE_DIR/.hints"

    pi "Generating cryptographic keys..."
    local -a PASSES=("")
    for i in $(seq 1 20); do PASSES+=("$(gen_pass)"); done

    pi "Constructing hardened terminals..."
    build_l01 "${PASSES[1]}"  && pg "BOOT_SECTOR      [01] ✓"
    build_l02 "${PASSES[2]}"  && pg "NEGATIVE_SPACE   [02] ✓"
    build_l03 "${PASSES[3]}"  && pg "WHITESPACE       [03] ✓  [+extra decoy]"
    build_l04 "${PASSES[4]}"  && pg "SPECTER          [04] ✓  [+lookalike decoys]"
    build_l05 "${PASSES[5]}"  && pg "FORENSICS        [05] ✓  [+ASCII text trap]"
    build_l06 "${PASSES[6]}"  && pg "INTERCEPT        [06] ✓  [+fake token lines]"
    build_l07 "${PASSES[7]}"  && pg "FREQUENCY        [07] ✓"
    build_l08 "${PASSES[8]}"  && pg "DECODE_ALPHA     [08] ✓  [+encoded decoy]"
    build_l09 "${PASSES[9]}"  && pg "DECODE_BRAVO     [09] ✓  [+cipher decoy]"
    build_l10 "${PASSES[10]}" && pg "PHANTOM_SIGNAL   [10] ✓  [+multiple strings]"
    build_l11 "${PASSES[11]}" && pg "THE_MAZE         [11] ✓  [+deep decoy targets]"
    build_l12 "${PASSES[12]}" && pg "DEEP_ARCHIVE     [12] ✓  [+decoy archive]"
    build_l13 "${PASSES[13]}" && pg "SETUID_HUNT      [13] ✓  [+SGID trap]"
    build_l14 "${PASSES[14]}" && pg "SIGNAL_DROP      [14] ✓  [portable nc]"
    build_l15 "${PASSES[15]}" && pg "DEAD_DROP        [15] ✓  [+vault decoy]"
    build_l16 "${PASSES[16]}" && pg "CRONTAB          [16] ✓  [+extra credential]"
    build_l17 "${PASSES[17]}" && pg "ENV_LEAK         [17] ✓"
    build_l18 "${PASSES[18]}" && pg "WEB_OF_LIES      [18] ✓  [+JSON readable trap]"
    build_l19 "${PASSES[19]}" && pg "HEX_GHOST        [19] ✓  [+multiple fake strings]"
    build_l20 "${PASSES[20]}" && pg "PIPELINE         [20] ✓  [+suspended admin decoy]"

    # [UPGRADE UP-11] Apply permission hardening AFTER all levels built
    pi "Applying security hardening..."
    chmod 700 "$CORE_DIR"
    # Lock all core files to chmod 000 — only _read_core() can unlock temporarily
    chmod 000 "$CORE_DIR/"*.hash 2>/dev/null
    chmod 000 "$CORE_DIR/"*.plain 2>/dev/null
    pg "Core storage locked (chmod 000)"

    # [UPGRADE UP-13] Environment hardening — game dir not exported to child processes
    # The GAME_DIR variable stays in parent shell scope, not inherited by game sub-shells
    # .gi file provides scoped _NX_DIR without leaking GAME_DIR/CORE_DIR directly
    chmod 700 "$GAME_DIR"   # Owner-only access to .nexus root
    pg "Game directory access restricted (chmod 700)"

    trap - INT TERM

    echo ""
    pg "NEXUS v${VERSION} online. 20 hardened terminals armed."
    echo -e "${C}Run:${N} bash $(basename "$0") play\n"
}

cmd_play() {
    [[ ! -d "$GAME_DIR" ]] && { pe "Not set up. Run: bash $0 setup"; exit 1; }
    load_state

    # SESSION ISOLATION: clear stale speedrun state on normal play entry
    if [[ "$SPEEDRUN" == "1" ]]; then
        SPEEDRUN=0; SR_START=""; save_state
    fi

    [[ "${2:-}" == "--timed" || "${TIMED_MODE:-0}" == "1" ]] && TIMED_MODE=1

    while true; do
        banner
        local lvl_int=$(( 10#${LEVEL:-01} ))
        local ac; ac=$(echo "${ACHIEVEMENTS:-}" | tr '|' '\n' | grep -c ':' 2>/dev/null || echo 0)

        if [[ $lvl_int -gt $TOTAL_LEVELS ]]; then
            echo -e " ${Y}◆ ALL LEVELS COMPLETE${N}\n"
            echo -e " ${W}[1]${N} Start SPEEDRUN MODE"
            echo -e " ${W}[2]${N} View achievements"
            echo -e " ${W}[3]${N} Export report"
            echo -e " ${W}[4]${N} Leaderboard"
            echo -e " ${W}[5]${N} Quit\n"
            read -rp "$(echo -e "${C}nexus> ${N}")" choice
            case "$choice" in
                1) _start_speedrun ;;
                2) _show_achievements_menu ;;
                3) cmd_report ;;
                4) cmd_leaderboard; read -rp "Press Enter..." ;;
                5|q*|e*) save_state; echo -e "${D}Progress saved.${N}\n"; break ;;
            esac
            continue
        fi

        [[ "$TIMED_MODE" == "1" ]] && {
            local lim; lim=$(level_time_limit "$lvl_int")
            echo -e " ${R}⏱ TIMED MODE — $(( lim / 60 )):00 budget for Level ${LEVEL}${N}\n"
        }
        echo -e " ${W}OPERATIVE STATUS${N}"
        echo -e "  Level  : ${Y}${LEVEL} / ${TOTAL_LEVELS}${N}"
        echo -e "  Score  : ${G}${SCORE} pts${N}"
        echo -e "  Medals : ${M}${ac}${N}"
        progress_bar; echo ""

        echo -e " ${W}[1]${N} Enter terminal — Level ${LEVEL}"
        echo -e " ${W}[2]${N} View objective"
        echo -e " ${W}[3]${N} Achievements"
        echo -e " ${W}[4]${N} Leaderboard"
        echo -e " ${W}[5]${N} Quit\n"

        read -rp "$(echo -e "${C}nexus> ${N}")" choice
        case "$choice" in
            1) launch_shell "$LEVEL"; load_state ;;
            2)
                echo -e "\n${C}── LEVEL ${LEVEL} OBJECTIVE ──────────────────────${N}"
                cat "$LEVELS_DIR/level${LEVEL}/objective" 2>/dev/null
                echo -e "${C}──────────────────────────────────────────${N}\n"
                read -rp "Press Enter..."
                ;;
            3) _show_achievements_menu ;;
            4) cmd_leaderboard; read -rp "Press Enter..." ;;
            5|q*|e*) save_state; echo -e "${D}Progress saved. Stay sharp.${N}\n"; break ;;
        esac
    done
}

_show_achievements_menu() {
    echo -e "\n${M}══ ACHIEVEMENTS ══${N}"
    if [[ -z "${ACHIEVEMENTS:-}" ]]; then echo "  None unlocked yet."
    else
        echo "$ACHIEVEMENTS" | tr '|' '\n' | grep ':' | cut -d: -f2- | \
            while IFS= read -r a; do echo -e "  🏆  $a"; done
    fi
    echo ""; read -rp "Press Enter..."
}

_start_speedrun() {
    pw "Starting SPEEDRUN — regenerating all passwords..."
    local sr_ts; sr_ts=$(date +%s)
    cmd_setup
    load_state
    SPEEDRUN=1; SR_START="$sr_ts"; SCORE=0; LEVEL="01"
    save_state
    pg "Speedrun started. Timer running. Good luck."
    sleep 1
}

cmd_reset() {
    read -rp "$(echo -e "${Y}[~] Wipe ALL progress? [y/N]: ${N}")" c
    [[ "$c" != [yY] ]] && { echo "Aborted."; return; }
    LEVEL="01"; SCORE=0; ACHIEVEMENTS=""
    SPEEDRUN=0; SR_START=""; SR_BEST=""; COMPLETED=0
    _init_hint_vars
    save_state; : > "$SAVE_DIR/.hints"
    find "$LEVELS_DIR" -name "hint_pos"  -exec sh -c 'echo 0 > "$1"' _ {} \; 2>/dev/null
    find "$LEVELS_DIR" -name ".attempts" -exec sh -c 'echo 0 > "$1"' _ {} \; 2>/dev/null
    pg "Progress wiped. Run: bash $0 play"
}

cmd_status() {
    [[ ! -f "$SAVE_DIR/state" ]] && { pe "No save found. Run: bash $0 setup"; exit 1; }
    load_state; banner
    local ac; ac=$(echo "${ACHIEVEMENTS:-}" | tr '|' '\n' | grep -c ':' 2>/dev/null || echo 0)
    local max=$(( TOTAL_LEVELS * 100 ))
    echo -e " ${W}OPERATIVE REPORT${N}"
    echo -e "  Level  : ${Y}${LEVEL} / ${TOTAL_LEVELS}${N}"
    echo -e "  Score  : ${G}${SCORE} / ${max} pts${N}"
    echo -e "  Grade  : ${C}$(get_grade $SCORE)${N}"
    echo -e "  Medals : ${M}${ac}${N}"
    [[ "$SPEEDRUN" == "1" && -n "$SR_START" ]] && {
        local e=$(( $(date +%s) - SR_START ))
        echo -e "  Sprint : ${R}⏱ $(( e/60 ))m $(( e%60 ))s running${N}"
    }
    [[ -n "${SR_BEST:-}" ]] && \
        echo -e "  Best   : ${Y}$(( SR_BEST/60 ))m $(( SR_BEST%60 ))s${N}"
    echo ""; progress_bar; echo ""
    [[ -n "${ACHIEVEMENTS:-}" ]] && {
        echo "$ACHIEVEMENTS" | tr '|' '\n' | grep ':' | cut -d: -f2- | \
            while IFS= read -r a; do echo -e "   🏆  $a"; done
        echo ""
    }
}

cmd_leaderboard() {
    local lb="$SAVE_DIR/leaderboard.txt"
    echo -e "\n${Y}╔═══════════════════════════════════════════════════╗"
    echo    "║              NEXUS LEADERBOARD                    ║"
    echo -e "╚═══════════════════════════════════════════════════╝${N}"
    if [[ ! -f "$lb" || ! -s "$lb" ]]; then
        echo -e "${D}  No entries yet. Complete the game to be listed.${D}\n"; return
    fi
    printf "  %-4s %-18s %-8s %-6s %s\n" "RANK" "OPERATIVE" "SCORE" "LVL" "DATE"
    echo   "  ──────────────────────────────────────────────────"
    sort -t'|' -k3 -rn "$lb" | head -15 | \
        awk -F'|' '{printf "  %-4d %-18s %-8s %-6s %s\n", NR, $2, $3" pts", $4, $1}'
    echo ""
}

_skills_for_level() {
    local reached; reached=$(( 10#${1:-0} ))
    local -a map=(
        "01:File reading and path manipulation (cat)"
        "02:Special filename handling (./ prefix)"
        "03:Filename whitespace handling (quoting, escaping)"
        "04:Hidden file enumeration (ls -la)"
        "05:File type identification (file command)"
        "06:Pattern searching in large files (grep)"
        "07:Duplicate line filtering (sort | uniq)"
        "08:Base64 encoding/decoding (base64 -d)"
        "09:Character substitution ciphers (tr, ROT13)"
        "10:Binary string extraction (strings, grep -a)"
        "11:Recursive file search (find -name -type)"
        "12:Multi-layer archive decompression (gzip, bzip2)"
        "13:SUID binary enumeration (find -perm -4000)"
        "14:Network socket communication (nc, /dev/tcp)"
        "15:Credential enumeration in hidden directories"
        "16:Hardcoded credential discovery (grep -r)"
        "17:Environment variable credential exposure (env)"
        "18:File type spoofing detection (file + magic bytes)"
        "19:Binary analysis with chained decode (strings + base64)"
        "20:Multi-stage extraction pipelines (grep|cut|base64)"
    )
    for entry in "${map[@]}"; do
        local lvl="${entry%%:*}"
        local skill="${entry#*:}"
        [[ $(( 10#$lvl )) -le $reached ]] && printf "  ✓ %s\n" "$skill"
    done
}

cmd_report() {
    [[ ! -f "$SAVE_DIR/state" ]] && { pe "No save found."; return; }
    load_state
    local ac; ac=$(echo "${ACHIEVEMENTS:-}" | tr '|' '\n' | grep -c ':' 2>/dev/null || echo 0)
    local max=$(( TOTAL_LEVELS * 100 ))
    local grade; grade=$(get_grade "$SCORE")
    local lvl_reached=$(( 10#${LEVEL:-1} - 1 ))
    local outfile="$HOME/nexus_report_$(date +%Y%m%d_%H%M).txt"
    {
    cat << REPORT
╔═══════════════════════════════════════════════════════╗
║          NEXUS — OPERATION: ZERO DAY                  ║
║              COMPLETION CERTIFICATE                   ║
╚═══════════════════════════════════════════════════════╝

  Operative   : $(whoami)
  Date        : $(date '+%Y-%m-%d %H:%M')
  Version     : $VERSION (Maximum Hardened)

╔═══════════════════════════════════════════════════════╗
║  PERFORMANCE SUMMARY                                  ║
╚═══════════════════════════════════════════════════════╝
  Score       : $SCORE / $max pts
  Grade       : $grade
  Level       : $lvl_reached / $TOTAL_LEVELS completed
  Medals      : $ac achievements
REPORT
    [[ -n "${SR_BEST:-}" ]] && \
        printf '  Best Speedrun : %dm %ds\n' "$(( SR_BEST/60 ))" "$(( SR_BEST%60 ))"
    cat << REPORT2

╔═══════════════════════════════════════════════════════╗
║  SKILLS DEMONSTRATED (levels reached only)           ║
╚═══════════════════════════════════════════════════════╝
REPORT2
    _skills_for_level "$lvl_reached"
    cat << REPORT3

╔═══════════════════════════════════════════════════════╗
║  ACHIEVEMENTS UNLOCKED                               ║
╚═══════════════════════════════════════════════════════╝
REPORT3
    if [[ -n "${ACHIEVEMENTS:-}" ]]; then
        echo "$ACHIEVEMENTS" | tr '|' '\n' | grep ':' | cut -d: -f2- | \
            while IFS= read -r a; do printf "  🏆  %s\n" "$a"; done
    else
        echo "  None unlocked."
    fi
    echo ""
    echo "  — NEXUS WARGAME v${VERSION} — $(date +%Y)"
    } > "$outfile"
    pg "Report saved: $outfile"
    local lvl_int=$(( 10#${LEVEL:-1} ))
    if [[ $lvl_int -gt $TOTAL_LEVELS ]]; then
        read -rp "$(echo -e "${C}[?] Add to leaderboard? Operative name (Enter to skip): ${N}")" lname
        [[ -n "$lname" ]] && {
            echo "$(date +%Y-%m-%d)|${lname}|${SCORE}|$(( lvl_int - 1 ))/20" \
                >> "$SAVE_DIR/leaderboard.txt"
            pg "Added as '$lname'"
        }
    fi
}

# =============================================================================
# cmd_verify — environment integrity check without rebuild
# [UPGRADE UP-3] Now checks CORE_DIR for .hash files instead of level dirs
# =============================================================================
cmd_verify() {
    [[ ! -d "$GAME_DIR" ]] && { pe "Not set up. Run: bash $0 setup"; exit 1; }
    pi "Verifying NEXUS v${VERSION} installation..."
    local ok=1 warn=0
    for i in $(seq -w 1 20); do
        local ldir="$LEVELS_DIR/level$i"
        local hfile="$CORE_DIR/$i.hash"
        if [[ ! -d "$ldir/challenge" ]]; then
            pe "Level $i: challenge directory MISSING — run setup to rebuild"
            ok=0; continue
        fi
        if [[ ! -e "$hfile" ]]; then
            pe "Level $i: hash file MISSING from core — run setup to rebuild"
            ok=0; continue
        fi
        # Temporarily read hash to verify it's valid sha256
        local h; h=$(_read_core "$hfile")
        if [[ ${#h} -ne 64 ]]; then
            pw "Level $i: hash malformed (len=${#h}, expected 64)"
            warn=$(( warn + 1 ))
        fi
    done
    # State file check
    if [[ -f "$SAVE_DIR/state" ]]; then
        load_state
        pg "State file: OK (checksum verified)"
    else
        pw "State file: not found (run 'play' to create)"
    fi
    # Log directory check
    [[ -d "$GAME_DIR/logs" ]] && pg "Log directory: present" \
        || pw "Log directory: missing (will be created on next setup)"
    [[ $ok -eq 1 && $warn -eq 0 ]] && pg "All 20 levels verified. Environment is clean." \
        || pw "Issues found. Run: bash $0 setup to rebuild."
}

# =============================================================================
# MAIN
# =============================================================================

for arg in "$@"; do [[ "$arg" == "--timed" ]] && TIMED_MODE=1; done

case "${1:-help}" in
    setup)       cmd_setup        ;;
    play)        cmd_play "$@"    ;;
    reset)       cmd_reset        ;;
    status)      cmd_status       ;;
    verify)      cmd_verify       ;;
    leaderboard) cmd_leaderboard  ;;
    report)      cmd_report       ;;
    *)
        banner
        echo -e " ${W}USAGE:${N} bash $0 <command> [flags]\n"
        echo "  setup           — build environment (run first)"
        echo "  play            — start / continue"
        echo "  play --timed    — timed mode (scaled per-level budget)"
        echo "  status          — progress report with visual bar"
        echo "  verify          — check installation integrity"
        echo "  leaderboard     — top scores"
        echo "  report          — export completion certificate"
        echo "  reset           — wipe progress"
        echo ""
        echo -e " ${D}Required: bash sha256sum base64 gzip bzip2 awk${N}"
        echo -e " ${D}Optional: nc (L14)  xxd (L19)  strings (L10/L19)${N}"
        echo -e " ${D}Termux:   pkg install coreutils bzip2 binutils netcat${N}\n"
        ;;
esac
