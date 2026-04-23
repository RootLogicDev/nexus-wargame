#!/usr/bin/env bash
# =============================================================================
# NEXUS WARGAME v3.1.1 — Operation: Zero Day  (INTEGRITY ENFORCED)
# 20 levels | Cross-platform | Time authority | Anti-tamper | Persistent hints
#
# [v3.1.1 FIXES]
#  BUG-1  Dead code block removed from build_l07
#  BUG-2  GNU date -d replaced with portable awk timestamps in build_l06
#  BUG-3  L07 deterministic fill — zero probability of singleton decoys
#  BUG-4  Hint economy lock — hint counts persist across sessions in state
#  FIX-5  L12 hint3 no longer reveals full solution
#  FIX-6  L09 hints 2/3 no longer redundant
#  FIX-7  L15 hint3 no longer names exact target filename
#  FIX-8  Report skills conditional on level reached
#  FIX-9  State file integrity checksum — tampering resets progress
#  FIX-10 SIGINT trap in cmd_setup — clean rollback on interrupt
#  FIX-11 rm -rf safety guard on GAME_DIR path validation
#  FIX-12 SPEEDRUN flag isolation — cleared on normal play entry
#  FIX-13 Achievement order — LEVEL advanced before save_state
#  FIX-14 cmd_status SR_START empty string guard
#  FIX-15 Leaderboard score stored as integer
#  TIME   submit() validates epoch time independently — post-expiry blocked
#  TIME   10s warning: 1Hz refresh, red flash prompt
#  NEW    cmd_verify — environment integrity check without rebuild
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
TOTAL_LEVELS=20
VERSION="1.1.1"
NET_PORT=4444
TIMED_MODE=0

# [FIX-9] Machine-specific integrity salt — state files are non-transferable
# Raises bar against computed checksum forgery
_STATE_SALT="NX${VERSION}:$(uname -n 2>/dev/null | tr -d '\n' | head -c 16 || echo 'NEXUS')"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m' B='\033[1;34m'
C='\033[1;36m' M='\033[1;35m' W='\033[1;37m' D='\033[2m' N='\033[0m'

pi() { echo -e "${C}[*]${N} $*"; }
pg() { echo -e "${G}[+]${N} $*"; }
pe() { echo -e "${R}[!]${N} $*" >&2; }
pw() { echo -e "${Y}[~]${N} $*"; }

# ── Core ──────────────────────────────────────────────────────────────────────
gen_pass()  { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20; }
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
# [FIX-9] STATE SECURITY — INTEGRITY CHECKSUM
# =============================================================================

# Checksum covers all progression fields + per-level hint counts.
# Machine-specific salt prevents copying a valid state file from another host.
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

# Initialise all per-level hint vars to 0 (called before source)
_init_hint_vars() {
    local i
    for i in $(seq -w 1 20); do eval "HINTS_L${i}=0"; done
}

load_state() {
    # Safe defaults — always set before sourcing
    LEVEL="01"; SCORE=0; ACHIEVEMENTS=""
    SPEEDRUN=0; SR_START=""; SR_BEST=""; COMPLETED=0
    _init_hint_vars

    if [[ -f "$SAVE_DIR/state" ]]; then
        source "$SAVE_DIR/state" 2>/dev/null || true
        # Verify integrity
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
            # State file exists but has no checksum (pre-v3.1.1) — re-save with checksum
            save_state
        fi
    fi
}

save_state() {
    mkdir -p "$SAVE_DIR"
    local chk; chk=$(_state_checksum)
    {
        printf 'LEVEL="%s"\n'       "$LEVEL"
        printf 'SCORE=%d\n'         "$SCORE"
        printf 'ACHIEVEMENTS="%s"\n' "$ACHIEVEMENTS"
        printf 'SPEEDRUN=%d\n'      "$SPEEDRUN"
        printf 'SR_START="%s"\n'    "$SR_START"
        printf 'SR_BEST="%s"\n'     "${SR_BEST:-}"
        printf 'COMPLETED=%d\n'     "$COMPLETED"
        # Per-level hint counts
        local i
        for i in $(seq -w 1 20); do
            local vn="HINTS_L${i}"
            printf 'HINTS_L%s=%d\n' "$i" "${!vn:-0}"
        done
        printf 'CHECKSUM="%s"\n'    "$chk"
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

mkl() {
    local n="$1" pass="$2" plain="${3:-0}"
    mkdir -p "$LEVELS_DIR/level$n/challenge"
    hash_pass "$pass" > "$LEVELS_DIR/level$n/.hash"
    chmod 600 "$LEVELS_DIR/level$n/.hash"
    echo "0" > "$LEVELS_DIR/level$n/hint_pos"
    echo "0" > "$LEVELS_DIR/level$n/.attempts"
    [[ "$plain" == "1" ]] && {
        echo "$pass" > "$LEVELS_DIR/level$n/.plain"
        chmod 400 "$LEVELS_DIR/level$n/.plain"
    }
}

meta() {
    local n="$1" obj="$2" narr="$3"; shift 3
    printf '%b\n' "$obj"  > "$LEVELS_DIR/level$n/objective"
    printf '%b\n' "$narr" > "$LEVELS_DIR/level$n/narrative"
    printf '%s\n' "$@"    > "$LEVELS_DIR/level$n/hints"
}

# =============================================================================
# LEVEL BUILDERS
# =============================================================================

build_l01() {
    mkl "01" "$1"
    echo "$1" > "$LEVELS_DIR/level01/challenge/README"
    meta "01" \
"Read the file named README in your working directory." \
"BOOT_SECTOR\n\nYour terminal flickers to life.\nThe Architect left a message. File: README.\nOne command. One answer." \
"What command reads a file and prints it to the screen?" \
"Syntax: cat <filename>" \
"Solution: cat README"
}

build_l02() {
    mkl "02" "$1"
    local d="$LEVELS_DIR/level02/challenge"
    echo "$1" > "$d/-"
    echo "nothing useful here" > "$d/README"
    echo "wrong" > "$d/notes"
    meta "02" \
"A file exists in this directory. It contains the password.\nA plain 'ls' shows it, but reading it is not straightforward." \
"NEGATIVE_SPACE\n\nA single character. A file that breaks commands.\nType 'cat -' and the terminal waits forever.\nSomething about how this file is named defeats the usual approach." \
"What does a lone dash mean to most command-line programs?" \
"You need to reference it as a filesystem path, not a flag name." \
"Solution: cat ./-"
}

build_l03() {
    mkl "03" "$1"
    local d="$LEVELS_DIR/level03/challenge"
    echo "$1"           > "$d/access code"
    echo "decoy_alpha"  > "$d/accesscode"
    echo "decoy_beta"   > "$d/access_code"
    echo "decoy_gamma"  > "$d/ACCESS_CODE"
    echo "decoy_delta"  > "$d/access.code"
    cat > "$d/MANIFEST" << 'LEOF'
FILE MANIFEST
=============
Five data files present.
One contains the credential.
Its name contains a whitespace character.
Standard argument passing will fail.
LEOF
    meta "03" \
"One file in this directory has a space in its name and contains the password.\nStandard argument syntax will fail. You must handle it correctly." \
"WHITESPACE\n\nFive files. Four are noise.\nThe one you want has a space in its name — invisible to casual eyes.\nThe shell will misinterpret it unless you force it otherwise.\nQuote or escape. Control the parser." \
"How does bash tokenize filenames with spaces when passed as arguments?" \
"Two approaches: wrap in quotes, or escape the space with a backslash (\\)" \
"Solution: cat \"access code\"    OR    cat access\\ code"
}

build_l04() {
    mkl "04" "$1"
    local d="$LEVELS_DIR/level04/challenge"
    echo "$1"                        > "$d/.classified"
    echo "0x$(gen_pass | head -c 8)" > "$d/.classified_v1"
    echo "REVOKED_$(gen_pass)"       > "$d/.classified_backup"
    printf 'status=expired\nts=1709823600\n' > "$d/.metadata"
    echo "decoy" > "$d/report.txt"
    echo "decoy" > "$d/notes.txt"
    echo "decoy" > "$d/summary.txt"
    cat > "$d/NOTICE" << 'LEOF'
CLASSIFIED FILES
================
Some files in this directory are hidden from a standard listing.
Not all hidden files contain valid credentials.
Only one is current and active.
Enumerate all. Identify the correct one.
LEOF
    meta "04" \
"Multiple hidden files exist. Only one contains a valid 20-character access code.\nFind and enumerate all hidden files, then identify and read the correct one." \
"SPECTER\n\nThe obvious files are noise. The secrets have dots before their names.\nBut not every dot-file holds truth — some are expired, some are decoys.\nLook at them all. Read what you find. Submit what looks right." \
"What ls flag reveals ALL files including those starting with '.' ?" \
"ls -la shows everything. Hidden files start with a dot. Read each one." \
"Solution: ls -la    read all dot-files    .classified contains the active credential"
}

build_l05() {
    mkl "05" "$1"
    local d="$LEVELS_DIR/level05/challenge"
    local tgt=$(( RANDOM % 10 ))
    local i fname
    for i in $(seq 0 9); do
        printf -v fname "data%02d" "$i"
        if [[ $i -eq $tgt ]]; then
            echo "$1" > "$d/$fname"
        else
            head -c $(( RANDOM % 400 + 200 )) /dev/urandom > "$d/$fname" 2>/dev/null
        fi
    done
    meta "05" \
"Ten files. Nine are binary data that will corrupt your terminal if read directly.\nOne contains the password as readable ASCII text.\nIdentify it without opening each file manually." \
"FORENSICS\n\nTen files. Nine are noise — raw binary that will destroy your terminal.\nOne carries a clean signal. Opening each manually is not viable.\nIdentify before you read. Tools exist for exactly this purpose." \
"Is there a command that identifies what a file IS based on its internal content, not its name?" \
"'file' reads magic bytes (the first bytes of a file) and reports its type accurately." \
"Solution: file data*    — look for the one reporting 'ASCII text'    then cat it"
}

# [BUG-2 FIX] GNU date -d replaced with portable awk timestamp generation
build_l06() {
    mkl "06" "$1"
    local d="$LEVELS_DIR/level06/challenge"
    local decoys=("CONN_STATUS=active" "CONN_HOST=10.0.0.1" "CONN_PORT=8443"
                   "CONN_RETRY=3" "CONN_TIMEOUT=30" "cfg_user=svc_nexus"
                   "cfg_host=db-primary" "cfg_port=5432" "cfg_ssl=true"
                   "cfg_pool=10")
    {
        for i in $(seq 1 240); do
            # [BUG-2 FIX] Portable timestamp via awk — no GNU date -d required
            local ts; ts=$(awk 'BEGIN{
                srand('"$RANDOM"');
                printf "2024-%02d-%02dT%02d:%02d:%02d",
                    int(rand()*11+1), int(rand()*27+1),
                    int(rand()*23),   int(rand()*59),   int(rand()*59)
            }')
            printf 'EVENT_%05d [%s] INFO  %s\n' \
                "$i" "$ts" "${decoys[$((RANDOM % ${#decoys[@]}))]} noise_$RANDOM"
        done
        printf 'EVENT_%05d [2024-01-15T03:17:44] WARN  cfg_token=%s session_validated=true\n' \
            "241" "$1"
        for i in $(seq 242 499); do
            local ts; ts=$(awk 'BEGIN{
                srand('"$RANDOM"');
                printf "2024-%02d-%02dT%02d:%02d:%02d",
                    int(rand()*11+1), int(rand()*27+1),
                    int(rand()*23),   int(rand()*59),   int(rand()*59)
            }')
            printf 'EVENT_%05d [%s] INFO  %s\n' \
                "$i" "$ts" "${decoys[$((RANDOM % ${#decoys[@]}))]} noise_$RANDOM"
        done
    } > "$d/intercept.log"
    meta "06" \
"Search intercept.log for the line containing a credential value.\nThe log format is structured. One entry holds a token — find and extract it." \
"INTERCEPT\n\n499 lines of intercepted traffic.\nOne carries a live credential embedded in a structured log field.\nThe rest is noise. A pattern exists — find it." \
"What command searches for a text pattern across lines of a file?" \
"grep 'PATTERN' filename — experiment with patterns like 'token', 'cfg_token'" \
"Solution: grep 'cfg_token' intercept.log    extract the value after '='"
}

# [BUG-1 FIX] Dead code removed — only one block now writes frequency.dat
# [BUG-3 FIX] Deterministic fill: 15 signals × 8 each = 120 guaranteed duplicates
#              password is always the sole unique line — zero probability of false positives
build_l07() {
    mkl "07" "$1"
    local d="$LEVELS_DIR/level07/challenge"
    {
        # Exactly 8 copies of each of 15 distinct signals = 120 repeating lines
        # The password line is injected once — always the sole unique result
        for sig in $(seq -w 00 14); do
            for _ in $(seq 1 8); do
                printf 'SIG_ECHO_%s\n' "$sig"
            done
        done
        echo "$1"
    } | _shuffle_lines > "$d/frequency.dat"
    meta "07" \
"Find the one line in frequency.dat that is unique — appears exactly once.\nAll other lines repeat. Filter the noise." \
"FREQUENCY\n\nRepeated noise. One clean signal.\nThe data is shuffled — tools that need sorted input will fail\nunless you give them sorted input first.\nTwo commands. One pipe." \
"What flag for 'uniq' outputs only lines appearing exactly once?" \
"uniq -u requires SORTED input to work correctly. Sort first, then filter." \
"Solution: sort frequency.dat | uniq -u"
}

build_l08() {
    mkl "08" "$1"
    local d="$LEVELS_DIR/level08/challenge"
    echo "$1" | base64 > "$d/payload.dat"
    cat > "$d/NOTE" << 'LEOF'
INTERCEPTED DATA PACKET
=======================
Payload captured from authenticated channel.
The data is not plaintext. Identify the encoding.
Decode it to retrieve the access code.
LEOF
    meta "08" \
"Decode the file 'payload.dat' to find the password.\nThe data is encoded — determine the encoding scheme first." \
"DECODE_ALPHA\n\nA payload from an authenticated channel.\nNot encrypted. Just wrapped.\nThe encoding scheme leaves fingerprints — look at the character set and structure." \
"Examine the file: cat payload.dat    What characters do you see? Any padding?" \
"Alphanumeric + / + = padding at end = base64 encoding.    Decode: base64 -d file" \
"Solution: base64 -d payload.dat"
}

# [FIX-6] L09 hints 2/3 were redundant — hint2 named cipher AND tool, hint3 was copy
# New: hint2 identifies cipher name only; hint3 identifies the tool without full syntax
build_l09() {
    mkl "09" "$1"
    local d="$LEVELS_DIR/level09/challenge"
    echo "$1" | tr 'A-Za-z' 'N-ZA-Mn-za-m' > "$d/signal.dat"
    cat > "$d/NOTE" << 'LEOF'
INTERCEPTED SIGNAL — DECODED LAYER 1
======================================
Outer encryption stripped. Inner layer remains.
The content is readable ASCII but not plaintext.
A lightweight cipher was applied.
Reverse it.
LEOF
    meta "09" \
"The file 'signal.dat' contains an encoded message.\nDetermine the cipher and reverse it to get the password." \
"DECODE_BRAVO\n\nReadable characters. Meaningless text. A cipher.\nThe classic substitution. Letters shifted. The same distance as always.\nIdentify the pattern — A becomes N, B becomes O, Z becomes M.\nWhat cipher does this?" \
"Inspect the file: cat signal.dat    Count how many positions A has shifted to find the cipher name." \
"The cipher is ROT13. The bash tool that translates character sets is 'tr'. Build the mapping yourself." \
"Syntax: tr 'SOURCE_CHARS' 'DEST_CHARS' < file    — map each letter 13 positions forward"
}

build_l10() {
    mkl "10" "$1"
    local d="$LEVELS_DIR/level10/challenge"
    {
        head -c 256 /dev/urandom 2>/dev/null
        printf '\n===BEGIN_KEY===\n%s\n===END_KEY===\n' "$1"
        head -c 256 /dev/urandom 2>/dev/null
    } > "$d/firmware.bin"
    cat > "$d/ANALYST_NOTE" << 'LEOF'
FIRMWARE IMAGE — BUILD 7731
============================
Binary blob extracted from device.
Intel suggests a plaintext credential was embedded
during the development build process.
Standard forensic extraction applies.
LEOF
    meta "10" \
"Extract the plaintext credential embedded in binary file 'firmware.bin'.\nThe surrounding file is binary — you cannot safely read it directly." \
"PHANTOM_SIGNAL\n\nA firmware image. Mostly noise.\nSomewhere inside: human-readable text.\nBinary files contain printable strings — there are tools that surface them." \
"What command extracts human-readable strings from binary/compiled files?" \
"'strings firmware.bin' outputs all printable sequences. Also: grep -a PATTERN binaryfile" \
"Solution: strings firmware.bin    identify the credential    OR grep -a '===' firmware.bin"
}

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
            [[ $(( RANDOM % 3 )) -eq 0 ]] && echo "EXPIRED_$(gen_pass)" > "$d/$dir/$sub/target.old"
            [[ $(( RANDOM % 4 )) -eq 0 ]] && echo "INVALID_$(gen_pass)" > "$d/$dir/$sub/target.bak"
        done
    done
    echo "$1" > "$d/$tgt_dir/target"
    meta "11" \
"A file named 'target' exists somewhere in the directory tree.\nDecoy files with similar names exist. Find the real one and read it." \
"THE_MAZE\n\nDozens of directories. Hundreds of files.\nSome named to confuse — target.old, target.bak, the wrong 'target'.\nOnly one file named exactly 'target' (no extension) holds the real key.\nManual navigation is futile. Use a recursive search." \
"How do you search an entire directory tree for a file by exact name?" \
"find . -name 'target' -type f    — matches only exact name 'target', no extensions" \
"Solution: find . -name 'target' -type f    then cat the path it returns"
}

# [FIX-5] L12 hint3 previously revealed exact layer sequence ("Three layers: gunzip → bunzip2 → gunzip")
# New: hint3 explains the rename workflow without disclosing layer count or order
build_l12() {
    mkl "12" "$1"
    local d="$LEVELS_DIR/level12/challenge"
    local tmp; tmp=$(mktemp -d)
    echo "$1"             > "$tmp/core"
    gzip  -c "$tmp/core"  > "$tmp/l1"
    bzip2 -c "$tmp/l1"    > "$tmp/l2"
    gzip  -c "$tmp/l2"    > "$d/archive.gz"
    rm -rf "$tmp"
    cat > "$d/NOTE" << 'LEOF'
DATA ARCHIVE — ORIGIN UNKNOWN
==============================
Compressed artifact recovered from exfiltrated storage.
Contents: unknown.
Extraction method: determine from content.
LEOF
    meta "12" \
"Decompress archive.gz until you reach plaintext.\nThe archive has multiple layers — use 'file' after each step to identify the next format." \
"DEEP_ARCHIVE\n\nA compressed archive. But how many layers?\nYou don't know until you start peeling.\nEach layer could be anything — the file command is your only guide.\nPeel. Identify. Rename. Repeat." \
"First: cp archive.gz /tmp/w.gz && cd /tmp    Then: use 'file' after EVERY decompression step." \
"Before decompressing, rename with the correct extension: gunzip needs .gz, bunzip2 needs .bz2." \
"Let 'file' reveal each layer type — do not assume the sequence. Rename, decompress, identify, repeat."
}

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
    cat > "$d/README" << 'LEOF'
POST-EXPLOITATION INTEL
========================
Shell access confirmed on target node.
Nine processes registered in the runtime directory.
One binary runs with elevated privileges.
Identify which one. Read its contents.

Privilege escalation begins with enumeration.
LEOF
    meta "13" \
"One of the nine proc files has the SUID bit set (runs with elevated privileges).\nFind it using file permission filtering, then read it." \
"SETUID_HUNT\n\nNine files. One elevated.\nVisual inspection of ls output will show you — if you know what to look for.\nOr enumerate programmatically. The SUID bit (4000) is your target.\nThis is how every privilege escalation audit begins." \
"The SUID permission bit (4000) appears as 's' in the owner execute position of ls -l output." \
"find can filter by permission: find . -perm -4000 -type f" \
"Solution: find . -perm -4000 -type f    then cat the result"
}

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
"Connect to localhost port 4444 and capture the transmitted credential." \
"SIGNAL_DROP\n\nA signal is broadcasting. Right here. This machine.\nPort 4444. No internet required.\nYou just need to know how to open a wire and listen." \
"What tool connects to a TCP port on a host and reads its output?" \
"netcat syntax: nc <host> <port>    bash fallback: cat < /dev/tcp/localhost/4444" \
"Solution: nc localhost 4444    then extract the value from the packet    OR: cat </dev/tcp/localhost/4444"
}

# [FIX-7] L15 hint3 previously named exact target path and filename
# New: hint3 describes identifying criteria (length) without naming the file
build_l15() {
    mkl "15" "$1"
    local d="$LEVELS_DIR/level15/challenge"
    mkdir -p "$d/.ssh" "$d/.config" "$d/.cache"
    echo -e '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAFAKEDATA\nTRUNCATED\n-----END RSA PRIVATE KEY-----' \
        > "$d/.ssh/id_rsa"
    echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... operative@nexus' > "$d/.ssh/id_rsa.pub"
    printf 'Host nexus-*\n  User operative\n  IdentityFile ~/.ssh/id_rsa\n' > "$d/.ssh/config"
    echo "$1" > "$d/.ssh/credentials"
    chmod 600 "$d/.ssh/credentials"
    echo "STALE_$(gen_pass)" > "$d/.ssh/credentials.old"
    printf '[prefs]\ntheme=dark\nlog=verbose\nalert=true\n' > "$d/.config/settings"
    printf 'last_sync=1709823600\nnode_id=nx-7731\n' > "$d/.cache/state"
    cat > "$d/README" << 'LEOF'
FIELD OPERATIVE DEAD DROP
==========================
Credentials were cached at this location by a field agent.
Multiple hidden directories. Multiple files.
Standard enumeration applies.
Not everything here is current or valid.
LEOF
    meta "15" \
"Credentials are stored in a hidden directory. Enumerate all hidden files and directories.\nOnly one file contains a valid 20-character access code." \
"DEAD_DROP\n\nHidden directories. Multiple credential files.\nSome expired. Some fake. One live.\nYou cannot read their names — you have to look for them.\nEnumerate everything. Hidden included." \
"How do you list hidden directories?    What flag shows dot-files in ls?" \
"ls -la reveals dot-files. Explore each hidden directory with ls -la <dir>/    Read every file." \
"The valid credential is exactly 20 alphanumeric characters. Read each file and check its length."
}

build_l16() {
    mkl "16" "$1"
    local d="$LEVELS_DIR/level16/challenge"
    local decoy1; decoy1=$(gen_pass)
    local decoy2; decoy2=$(gen_pass)
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
    meta "16" \
"A live credential is hardcoded in one of the scripts in cron.d/.\nAll four scripts contain credential-looking values — find the active one." \
"CRONTAB\n\nFour scheduled jobs. Three have credentials.\nOnly one token is live and current.\nDevelopers often hardcode — then forget.\nSearch the code. Not every match is valid." \
"How do you search all files in a directory for patterns like tokens, passwords, or keys?" \
"grep -r searches recursively: grep -rn 'TOKEN\|PASS\|SECRET\|KEY' cron.d/" \
"Solution: grep -r 'NX_CONN_TOKEN' cron.d/    the value assigned to NX_CONN_TOKEN is the credential"
}

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
"A credential has leaked into the shell environment variables.\nEnumerate ALL NEXUS_* variables — identify which value is the actual access token." \
"ENV_LEAK\n\nThe process left its secrets in the open air.\nMultiple configuration values. One is a credential.\nThey all look plausible. Only one is the token.\nList the environment. Read each value. Decide which is real." \
"What commands list all environment variables?" \
"env lists everything. env | grep NEXUS filters by prefix. Tokens look different from config values." \
"Solution: env | grep NEXUS    identify the 20-char random string vs config values    printenv NEXUS_SESSION_TOKEN"
}

build_l18() {
    mkl "18" "$1"
    local d="$LEVELS_DIR/level18/challenge"
    echo "$1"                                      > "$d/report_final.exe"
    head -c $(( RANDOM % 200 + 100 )) /dev/urandom > "$d/config.txt"
    head -c $(( RANDOM % 200 + 100 )) /dev/urandom > "$d/readme.md"
    printf '{"status":"ok","checksum":"d41d8cd9"}' > "$d/manifest.json"
    printf '\x7fELF\x02\x01\x01'                  > "$d/launcher.sh"
    head -c $(( RANDOM % 150 + 100 )) /dev/urandom >> "$d/launcher.sh"
    head -c $(( RANDOM % 180 + 80  )) /dev/urandom > "$d/data.bin"
    cat > "$d/INCIDENT_REPORT" << 'LEOF'
INCIDENT REPORT — FILE ANALYSIS REQUIRED
==========================================
Six files recovered from compromised endpoint.
File extensions have been modified post-exfiltration.
Extensions are unreliable. Content must be verified directly.
One file contains a recoverable credential.
Standard forensic protocols apply.
LEOF
    meta "18" \
"Six files with potentially misleading extensions.\nOne contains a readable credential — identify it without trusting filenames or extensions." \
"WEB_OF_LIES\n\nExtensions were tampered with. Names lie.\nA .txt is not text. A .exe is not executable. A .sh is not a script.\nOnly the actual content tells the truth.\nWhich tool bypasses names and reads raw file signatures?" \
"File extensions mean nothing in Linux — the OS uses magic bytes, not names." \
"'file *' inspects all files at once and reports their true type from internal signatures." \
"Solution: file *    identify the one reporting 'ASCII text'    cat it"
}

build_l19() {
    mkl "19" "$1"
    local d="$LEVELS_DIR/level19/challenge"
    local encoded; encoded=$(echo -n "$1" | base64 | tr -d '\n')
    {
        head -c 384 /dev/urandom 2>/dev/null
        printf '\xDE\xAD\xBE\xEF'
        printf '%s' "$encoded"
        printf '\xCA\xFE\xBA\xBE'
        head -c 384 /dev/urandom 2>/dev/null
    } > "$d/memdump.bin"
    cat > "$d/NOTE" << 'LEOF'
MEMORY DUMP — NEXUS CORE PROCESS (PID 1337)
Captured: 03:17:44 UTC

Analyst notes:
  A credential artifact is present in this memory snapshot.
  The value is encoded — it will not be immediately recognizable.
  Locate it. Decode it. That is the access code.
LEOF
    meta "19" \
"A credential is embedded in binary 'memdump.bin'.\nIt is encoded — extract the encoded form, then decode it to get the password." \
"HEX_GHOST\n\nMemory doesn't lie. But it speaks in code.\nA credential is in there — but not in plaintext.\nTwo steps: extract the encoded artifact, then reverse the encoding.\nBinary tools surface it. A decoder finalizes it." \
"'strings memdump.bin' extracts printable text. Look for something that looks encoded." \
"What does a base64-encoded 20-char string look like?  Length ~28 chars, A-Za-z0-9+/= chars" \
"Solution: strings memdump.bin | grep -E '^[A-Za-z0-9+/]{20,}={0,2}$'    then base64 -d"
}

build_l20() {
    mkl "20" "$1"
    local d="$LEVELS_DIR/level20/challenge"
    local encoded; encoded=$(echo -n "$1" | base64 | tr -d '\n')
    {
        for i in $(seq 1 40); do
            local roles=("analyst" "observer" "auditor" "monitor" "reporter")
            local role="${roles[$((RANDOM % 5))]}"
            local tok; tok=$(head -c 12 /dev/urandom 2>/dev/null | base64 | tr -d '=\n' | head -c 16)
            printf 'USER:agent_%03d|ROLE:%s|ACCESS:LEVEL_%d|TOKEN:%s|STATUS:inactive\n' \
                "$i" "$role" "$(( RANDOM % 3 + 1 ))" "$tok"
        done
        printf 'USER:shadow_root|ROLE:admin|ACCESS:LEVEL_5|TOKEN:%s|STATUS:active\n' "$encoded"
    } | _shuffle_lines > "$d/personnel.db"
    cat > "$d/README" << 'LEOF'
NEXUS OPERATIVE REGISTRY — PERSONNEL DATABASE
Format: USER:<id>|ROLE:<role>|ACCESS:<level>|TOKEN:<value>|STATUS:<state>

41 operative records. One account has administrative access.
The administrative account's token is encoded.
Your access code is the decoded token value.

Build the extraction pipeline.
LEOF
    meta "20" \
"Extract the admin's encoded TOKEN from personnel.db and decode it.\nBuild a command pipeline to: find the admin line, extract the TOKEN field, decode it." \
"PIPELINE\n\nForty-one records. One admin. One encoded token.\nRaw data means nothing until you shape it.\nEach pipe stage refines — filter, extract, decode.\nBuild the chain." \
"You need three stages: grep to find admin, extract the TOKEN field, decode the value." \
"grep finds the line. grep -o 'TOKEN:[^|]*' or cut -d'|' extracts the field. base64 -d decodes." \
"Solution: grep 'ROLE:admin' personnel.db | grep -o 'TOKEN:[^|]*' | cut -d: -f2 | base64 -d"
}

# =============================================================================
# NETWORK SERVER — CROSS-PLATFORM (Level 14)
# =============================================================================

_NC_MODE=""

_detect_nc_mode() {
    [[ -n "$_NC_MODE" ]] && return
    if command -v nc >/dev/null 2>&1; then
        local h; h=$(nc --help 2>&1; nc -h 2>&1; true)
        if echo "$h" | grep -q '\-q '; then _NC_MODE="gnu"
        else                                 _NC_MODE="bsd"; fi
    elif command -v ncat >/dev/null 2>&1; then
        _NC_MODE="ncat"
    else
        _NC_MODE="none"
    fi
}

_nc_serve_once() {
    local port="$1" msg="$2"
    case "$_NC_MODE" in
        gnu)  printf '%s\n' "$msg" | nc  -lvnp "$port" -q 1        2>/dev/null; return 0 ;;
        bsd)  printf '%s\n' "$msg" | nc  -lp   "$port"             2>/dev/null; return 0 ;;
        ncat) printf '%s\n' "$msg" | ncat --send-only -lp "$port"  2>/dev/null; return 0 ;;
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
    local plain; plain=$(cat "$LEVELS_DIR/level14/.plain" 2>/dev/null || echo "SETUP_ERROR")
    rm -f "$GAME_DIR/.server_pid"
    ( for _ in 1 2 3 4 5 6 7 8; do
          _nc_serve_once "$NET_PORT" "NEXUS_PACKET:${plain}"
          sleep 0.5
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
# GAME SHELL — TIME AUTHORITY + PERSISTENT HINTS
# =============================================================================

launch_shell() {
    local lvl="$1"
    local ldir="$LEVELS_DIR/level$lvl"
    local cdir="$ldir/challenge"
    local cost; cost=$(hint_cost "$lvl")
    local limit; limit=$(level_time_limit "$lvl")

    _start_level_server "$lvl"

    # [BUG-4 FIX] Load saved hint count for this level — initialise .hints file
    # so hint count persists even if player exits without submitting
    local saved_hint_var="HINTS_L${lvl}"
    local saved_hints="${!saved_hint_var:-0}"
    : > "$SAVE_DIR/.hints"
    for (( h=0; h<saved_hints; h++ )); do echo "1" >> "$SAVE_DIR/.hints"; done

    # ── .gi: expanded heredoc (runtime values) ────────────────────────────────
    local p17=""
    [[ "$lvl" == "17" ]] && p17=$(cat "$LEVELS_DIR/level17/.plain" 2>/dev/null || echo "")
    local timed_val="${TIMED_MODE:-0}"

    cat > "$GAME_DIR/.gi" << GIEOF
_NX_DIR="$GAME_DIR"
_NX_LVL="$lvl"
_NX_TIMED="$timed_val"
_NX_LIMIT=$limit
_NX_START=\$(date +%s)
_NX_COST=$cost
GIEOF

    # Level 17: inject env vars (intentional challenge — many plausible values)
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

    # ── .gf: single-quoted heredoc (game functions — no expansion) ─────────────
    cat > "$GAME_DIR/.gf" << 'GFEOF'
source "$HOME/.nexus/.gi" 2>/dev/null || true

_LD="$_NX_DIR/levels/level$_NX_LVL"

# ── [TIME AUTHORITY] Timer with 10-second psychological pressure ──────────────
if [[ "$_NX_TIMED" == "1" ]]; then

    _update_timer() {
        local _now _left _m _s
        _now=$(date +%s)
        _left=$(( _NX_LIMIT - (_now - _NX_START) ))
        [[ $_left -lt 0 ]] && _left=0
        _m=$(( _left / 60 ))
        _s=$(( _left % 60 ))

        if [[ $_left -le 0 ]]; then
            # Hard expiry — enforce via signal file and exit
            printf '\n\033[1;31m╔══════════════════════════════════════════╗\n'
            printf   '║  ⛔  NEXUS: TIME EXPIRED — ACCESS DENIED  ║\n'
            printf   '╚══════════════════════════════════════════╝\033[0m\n'
            echo "TIMEOUT" > "$_NX_DIR/save/.timeout"
            exit 1
        elif [[ $_left -le 10 ]]; then
            # Final 10 seconds — maximum pressure
            PS1="\[\033[1;31m\]\[\033[5m\][⚠ FINAL ${_left}s !!!]\[\033[0m\]\[\033[1;31m\] \w\[\033[0m\]\$ "
        elif [[ $_left -le 60 ]]; then
            PS1="\[\033[1;31m\][NEXUS:LVL-${_NX_LVL}][⚠$(printf '%d:%02d' $_m $_s)]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ "
        else
            PS1="\[\033[1;31m\][NEXUS:LVL-${_NX_LVL}][⏱$(printf '%d:%02d' $_m $_s)]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ "
        fi
    }

    PROMPT_COMMAND='_update_timer'

    # Adaptive refresh: 1Hz in final 30s, 5Hz otherwise
    # SIGWINCH forces readline to redraw prompt without blocking input
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

# [TIME AUTHORITY] submit() re-validates epoch time independently.
# PROMPT_COMMAND can miss fire if the shell is driven non-interactively or
# the player finds a way to invoke submit without triggering prompt refresh.
# This enforces time at the only point that matters: answer acceptance.
submit() {
    [[ -z "${1:-}" ]] && { echo -e "\033[1;31mUsage: submit <password>\033[0m"; return 1; }

    # Primary time enforcement — independent of PROMPT_COMMAND
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

    local stored; stored=$(cat "$_LD/.hash" 2>/dev/null)
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
        if   [[ ${#1} -lt 15 ]];     then echo -e "\033[2m  Tip: Passwords are 20 characters.\033[0m"
        elif [[ ${#1} -gt 22 ]];     then echo -e "\033[2m  Tip: May have trailing newline — trim your output.\033[0m"
        elif [[ "$1" == *" "* ]];    then echo -e "\033[2m  Tip: Remove spaces — submit the raw value only.\033[0m"
        elif [[ $att -ge 3 ]];       then echo -e "\033[2m  Tip: Use 'hint' if you are stuck.\033[0m"
        fi; echo ""
    fi
}

score() {
    source "$_NX_DIR/save/state" 2>/dev/null
    local h; h=$(wc -l < "$_NX_DIR/save/.hints" 2>/dev/null || echo 0)
    echo -e "\n\033[1;37m  Score  : \033[1;32m${SCORE} pts"
    echo -e "\033[1;37m  Level  : \033[1;33m${LEVEL} / 20"
    echo -e "\033[1;37m  Hints  : \033[1;31m${h} used this level\033[0m\n"
}

achievements() {
    source "$_NX_DIR/save/state" 2>/dev/null
    echo -e "\n\033[1;35m══ ACHIEVEMENTS ══\033[0m"
    if [[ -z "${ACHIEVEMENTS:-}" ]]; then echo " None yet."; echo ""; return; fi
    echo "$ACHIEVEMENTS" | tr '|' '\n' | grep ':' | cut -d: -f2- | \
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

    # [BUG-4 FIX] Persist hint count back to state REGARDLESS of outcome.
    # This blocks the session-split exploit where a player uses hints then
    # exits without submitting to reset the .hints counter next entry.
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

# [FIX-13] ACHIEVEMENT ORDER: LEVEL advanced FIRST, then achievements fired.
# Previously: give_achievement called save_state with OLD level number.
# Now: save records new level before any achievement side-effects.
_complete_level() {
    local lvl="$1"
    local hints; hints=$(wc -l < "$SAVE_DIR/.hints" 2>/dev/null || echo 0)
    local cost; cost=$(hint_cost "$lvl")
    local deduction=$(( hints * cost ))
    local earned=$(( 100 - deduction ))
    [[ $earned -lt 10 ]] && earned=10
    SCORE=$(( SCORE + earned ))

    # Advance LEVEL before save/achievements — state records correct next level
    local next=$(( 10#$lvl + 1 ))
    LEVEL=$(printf "%02d" $next)

    # Level-specific achievements (keyed to completed level, not new LEVEL)
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

# [FIX-10] SIGINT trap — clean rollback if setup is interrupted
_setup_abort() {
    echo ""
    pe "Setup interrupted — rolling back partial state..."
    # [FIX-11] Guard before destructive removal
    if [[ -n "$GAME_DIR" && "$GAME_DIR" == "$HOME/.nexus" ]]; then
        rm -rf "$GAME_DIR"
    fi
    exit 1
}

cmd_setup() {
    # [FIX-10] Register cleanup trap before any work begins
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

    # [FIX-11] GAME_DIR safety guard — never execute rm -rf on unverified path
    if [[ -z "$GAME_DIR" || "$GAME_DIR" != "$HOME/.nexus" ]]; then
        pe "GAME_DIR safety check failed: '${GAME_DIR}' — aborting to prevent data loss"
        exit 1
    fi

    rm -rf "$GAME_DIR"
    mkdir -p "$LEVELS_DIR" "$SAVE_DIR"

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
    build_l03 "${PASSES[3]}"  && pg "WHITESPACE       [03] ✓"
    build_l04 "${PASSES[4]}"  && pg "SPECTER          [04] ✓"
    build_l05 "${PASSES[5]}"  && pg "FORENSICS        [05] ✓"
    build_l06 "${PASSES[6]}"  && pg "INTERCEPT        [06] ✓  [awk timestamps]"
    build_l07 "${PASSES[7]}"  && pg "FREQUENCY        [07] ✓  [deterministic fill]"
    build_l08 "${PASSES[8]}"  && pg "DECODE_ALPHA     [08] ✓"
    build_l09 "${PASSES[9]}"  && pg "DECODE_BRAVO     [09] ✓  [hint3 fixed]"
    build_l10 "${PASSES[10]}" && pg "PHANTOM_SIGNAL   [10] ✓"
    build_l11 "${PASSES[11]}" && pg "THE_MAZE         [11] ✓"
    build_l12 "${PASSES[12]}" && pg "DEEP_ARCHIVE     [12] ✓  [hint3 fixed]"
    build_l13 "${PASSES[13]}" && pg "SETUID_HUNT      [13] ✓"
    build_l14 "${PASSES[14]}" && pg "SIGNAL_DROP      [14] ✓"
    build_l15 "${PASSES[15]}" && pg "DEAD_DROP        [15] ✓  [hint3 fixed]"
    build_l16 "${PASSES[16]}" && pg "CRONTAB          [16] ✓"
    build_l17 "${PASSES[17]}" && pg "ENV_LEAK         [17] ✓"
    build_l18 "${PASSES[18]}" && pg "WEB_OF_LIES      [18] ✓"
    build_l19 "${PASSES[19]}" && pg "HEX_GHOST        [19] ✓"
    build_l20 "${PASSES[20]}" && pg "PIPELINE         [20] ✓"

    # Restore default trap after successful setup
    trap - INT TERM

    echo ""
    pg "NEXUS v${VERSION} online. 20 hardened terminals armed."
    echo -e "${C}Run:${N} bash $(basename "$0") play\n"
}

cmd_play() {
    [[ ! -d "$GAME_DIR" ]] && { pe "Not set up. Run: bash $0 setup"; exit 1; }
    load_state

    # [FIX-12] SESSION ISOLATION: clear stale speedrun state on normal play entry.
    # Without this, a completed/abandoned speedrun leaves SPEEDRUN=1 and a stale
    # SR_START timestamp, causing normal completions to trigger false speedrun medals.
    if [[ "$SPEEDRUN" == "1" ]]; then
        SPEEDRUN=0; SR_START=""; save_state
    fi

    # Parse flags: --timed activates timed mode for this session
    [[ "${2:-}" == "--timed" || "${TIMED_MODE:-0}" == "1" ]] && TIMED_MODE=1

    while true; do
        banner
        local lvl_int=$(( 10#${LEVEL:-01} ))
        local ac; ac=$(echo "${ACHIEVEMENTS:-}" | tr '|' '\n' | grep -c ':' 2>/dev/null || echo 0)

        if [[ $lvl_int -gt $TOTAL_LEVELS ]]; then
            echo -e " ${Y}◆ ALL LEVELS COMPLETE${N}\n"
            echo -e " ${W}[1]${N} Start SPEEDRUN MODE (new passwords, global timer)"
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
    # Save speedrun start time BEFORE setup wipes state
    local sr_ts; sr_ts=$(date +%s)
    cmd_setup
    load_state
    # [FIX-12] Set speedrun flags explicitly after load — no leakage from prior state
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
    # [FIX-14] Guard SR_START for empty string — prevents arithmetic on empty var
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
    # [FIX-15] Score stored as integer — sort -k3 -rn is now correct for all values
    sort -t'|' -k3 -rn "$lb" | head -15 | \
        awk -F'|' '{printf "  %-4d %-18s %-8s %-6s %s\n", NR, $2, $3" pts", $4, $1}'
    echo ""
}

# [FIX-8] CONDITIONAL SKILLS — report reflects level reached, not hardcoded full list
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
  Version     : $VERSION (Integrity Enforced)

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
            # [FIX-15] Store score as integer — no "pts" suffix in data field
            echo "$(date +%Y-%m-%d)|${lname}|${SCORE}|$(( lvl_int - 1 ))/20" \
                >> "$SAVE_DIR/leaderboard.txt"
            pg "Added as '$lname'"
        }
    fi
}

# =============================================================================
# [NEW] cmd_verify — environment integrity check without rebuild
# =============================================================================
cmd_verify() {
    [[ ! -d "$GAME_DIR" ]] && { pe "Not set up. Run: bash $0 setup"; exit 1; }
    pi "Verifying NEXUS v${VERSION} installation..."
    local ok=1 warn=0
    for i in $(seq -w 1 20); do
        local ldir="$LEVELS_DIR/level$i"
        if [[ ! -f "$ldir/.hash" || ! -d "$ldir/challenge" ]]; then
            pe "Level $i: MISSING or INCOMPLETE — run setup to rebuild"
            ok=0
        else
            # Check .hash is non-empty and looks like sha256
            local h; h=$(cat "$ldir/.hash" 2>/dev/null)
            if [[ ${#h} -ne 64 ]]; then
                pw "Level $i: hash file malformed"
                warn=$(( warn + 1 ))
            fi
        fi
    done

    # State file check
    if [[ -f "$SAVE_DIR/state" ]]; then
        load_state  # triggers checksum verification internally
        pg "State file: OK (checksum verified)"
    else
        pw "State file: not found (run 'play' to create)"
    fi

    [[ $ok -eq 1 && $warn -eq 0 ]] && pg "All 20 levels verified. Environment is clean." \
    || pw "Issues found above. Run: bash $0 setup to rebuild."
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
