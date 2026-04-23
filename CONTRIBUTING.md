# Contributing to NEXUS Wargame

NEXUS is a no-hand-holding offensive security training environment. Contributions
are welcome — but the bar is high. Every level must teach a real skill, resist
trivial solutions, and work identically on Termux and standard Linux.

---

## Table of Contents

1. [Ways to Contribute](#ways-to-contribute)
2. [Environment Setup](#environment-setup)
3. [Adding a New Level](#adding-a-new-level)
4. [Hint Design Rules](#hint-design-rules)
5. [Challenge Design Rules](#challenge-design-rules)
6. [Cross-Platform Requirements](#cross-platform-requirements)
7. [Testing Checklist](#testing-checklist)
8. [Submitting a Pull Request](#submitting-a-pull-request)
9. [Bug Reports](#bug-reports)

---

## Ways to Contribute

- **Bug fixes** — platform compatibility issues, logic errors, edge cases
- **New levels** — must follow the level design rules below
- **Documentation** — README improvements, usage examples
- **Platform testing** — confirming behavior on Termux, BSD, macOS, Arch

What we do **not** accept:
- Levels that trivially reveal answers in hints
- Levels that require internet access or external services
- Platform-specific code without a fallback
- Cosmetic changes without functional improvement

---

## Environment Setup

```bash
# Clone the repo
git clone https://github.com/RootLogicDev/nexus-wargame
cd nexus-wargame

# Required dependencies
apt install coreutils bzip2 binutils   # Debian/Ubuntu/Kali
pkg install coreutils bzip2 binutils   # Termux

# Optional (for specific levels)
apt install netcat xxd

# Build and test
bash wargame.sh setup
bash wargame.sh verify
bash wargame.sh play
```

---

## Adding a New Level

Each level consists of:

```
~/.nexus/levels/levelNN/
├── challenge/        ← player works inside here
├── .hash             ← SHA-256 of the password (auto-created by mkl)
├── .attempts         ← attempt counter
├── hint_pos          ← hint position tracker
├── objective         ← mission brief (shown by objective command)
├── narrative         ← story text (shown by story command)
└── hints             ← one hint per line, max 3
```

### Step 1 — Write the builder function

All level builders follow this pattern:

```bash
build_lNN() {
    # 1. Initialise the level directory and hash the password
    mkl "NN" "$1"

    # 2. Create challenge files
    local d="$LEVELS_DIR/levelNN/challenge"
    echo "$1" > "$d/target_file"          # real answer
    echo "decoy" > "$d/noise_file"        # distractor

    # 3. Set objective, narrative, and hints
    meta "NN" \
"One-sentence mission brief. State what the player needs to do." \
"CODE_NAME\n\nNarrative text.\nUse \\n for line breaks.\nKeep it under 6 lines." \
"Hint 1 — concept question, no commands" \
"Hint 2 — tool identification, no full syntax" \
"Hint 3 — syntax guidance, no complete solution"
}
```

### Step 2 — Register it in `cmd_setup`

```bash
build_lNN "${PASSES[NN]}" && pg "CODE_NAME       [NN] ✓"
```

Also add `"$(gen_pass)"` to the PASSES array initialization loop — it already runs `seq 1 20`, so update the upper bound.

### Step 3 — Add to TOTAL_LEVELS

```bash
TOTAL_LEVELS=21   # increment for each new level
```

### Step 4 — Add per-level hint var initialisation

`_init_hint_vars()` loops `seq -w 1 20` — update the bound to match `TOTAL_LEVELS`.

### Step 5 — Add achievement (optional)

In `_complete_level()`:
```bash
"NN") give_achievement "ACHIEVEMENT_ID" "Achievement Label — description" ;;
```

---

## Hint Design Rules

These are non-negotiable. Hints that violate them will be rejected.

**The three tiers:**

| Tier | Purpose | What it reveals | What it must NOT reveal |
|------|---------|-----------------|------------------------|
| Hint 1 | Conceptual | The domain concept | Any tool name |
| Hint 2 | Tool identification | Tool name only | Flags, syntax, command structure |
| Hint 3 | Syntax guidance | How to use the tool | The complete working command |

**Examples:**

```bash
# CORRECT hint progression for a grep level:
"How do you search for a specific pattern inside a large text file?"
"The 'grep' command searches for patterns. It operates on files or piped input."
"Syntax: grep 'PATTERN' filename    — the output is the matching line"

# WRONG — hint 3 gives complete solution:
"Solution: grep 'cfg_token' intercept.log"   # ← REJECTED

# WRONG — hint 1 names the tool:
"Use grep to find the pattern"               # ← REJECTED

# WRONG — hints 2 and 3 say the same thing:
"grep is the right tool here"
"grep is what you need"                      # ← REJECTED (redundant)
```

**Additional rules:**
- Never include the word "Solution:" in any hint
- Never name the exact target file in hint 3
- Each hint must reduce the search space — not repeat the previous hint
- Hints are cumulative costs. Hint 3 is expensive. Make each tier worth its price.

---

## Challenge Design Rules

**Bypass resistance** — think like an attacker first.

Before submitting a level, attempt to solve it using these trivial approaches:
- `cat *` — does wildcard expansion reveal the answer?
- `ls -laR` — does recursive listing give it away immediately?
- `grep -r '' .` — does grepping everything expose it?
- `find . -type f -exec cat {} \;` — does reading every file trivially work?

If any of these work in under 30 seconds without understanding the intended skill, the level needs more decoys or structural hardening.

**Decoy requirements:**
- At least 2 decoy files that look plausible but contain wrong values
- Decoys must use `gen_pass` so they are random and non-trivially identifiable as fake
- File names should not give away which is real (avoid names like `target.txt` when others are `noise1`, `noise2`)

**Answer determinism:**
- The answer must be exactly one value — no ambiguity
- `sort | uniq -u` levels must guarantee exactly one unique line (use fixed counts, not random)
- Binary levels must produce exactly one extractable string matching the expected pattern

**Skill mapping:**
- Each level must teach exactly one primary skill
- The skill must be genuinely useful in offensive security work (CTF, recon, post-exploitation, forensics)
- Document the skill in `CONTRIBUTING.md` and the level table in `README.md`

---

## Cross-Platform Requirements

All code must work identically on:
- Termux on Android (busybox variants, proot Kali)
- Ubuntu 20.04+
- Debian stable
- Kali Linux
- Arch Linux

**Forbidden constructs:**

```bash
# GNU date -d — fails on Termux/BSD
date -d "2024-01-15 03:00:00" '+%Y-%m-%dT%H:%M:%S'

# GNU sort -R — not in busybox
sort -R file

# Bash 4+ arrays with -A (associative) — check Termux bash version
declare -A map

# GNU-only find flags like -printf
find . -printf '%p\n'
```

**Required portable alternatives:**

```bash
# Timestamps — use awk
awk 'BEGIN{srand(SEED); printf "%04d-%02d-%02dT%02d:%02d:%02d", ...}'

# Shuffle — use _shuffle_lines() (already in codebase)
data | _shuffle_lines

# find output — use -exec or xargs
find . -name 'target' -type f -exec cat {} \;
```

**Test on Termux before submitting.** If you don't have Android access, note this in your PR and a maintainer will test it.

---

## Testing Checklist

Before opening a PR, verify every item:

```
Level functionality:
[ ] Level builds without errors during setup
[ ] Challenge files exist in the correct directory
[ ] Answer is solvable using only the intended method
[ ] submit <correct_answer> returns ACCESS GRANTED
[ ] submit <wrong_answer> returns incorrect feedback
[ ] All 3 hints reveal progressively more detail without giving full solution
[ ] find . -name 'target' (or equivalent trivial search) does NOT trivially bypass the level

Bypass resistance:
[ ] cat * does not reveal the answer
[ ] ls -laR does not make the answer obvious
[ ] Wildcard abuse (e.g., cat data0*) does not trivially solve it

Platform:
[ ] Works on Termux (or noted for maintainer testing)
[ ] Works on standard Linux (Ubuntu/Kali)
[ ] No GNU-only tools used without fallback

State:
[ ] bash wargame.sh verify passes after setup
[ ] bash wargame.sh status shows correct level
[ ] bash wargame.sh reset then setup works cleanly
```

---

## Submitting a Pull Request

1. Fork the repository
2. Create a branch: `git checkout -b level/NN-code-name` or `fix/description`
3. Make your changes
4. Run the full test checklist above
5. Open a PR with:
   - **What** — one sentence description
   - **Why** — what skill gap or bug this addresses
   - **Tested on** — platforms you verified
   - **Bypass attempts** — what trivial approaches you tested and blocked

PR title format:
```
[Level NN] CODE_NAME — brief description
[Fix] short description of what was wrong
[Docs] what was updated
```

---

## Bug Reports

Use the bug report issue template. Include:
- Platform and bash version (`bash --version`)
- The command that failed
- Expected vs actual output
- Whether it reproduces after `bash wargame.sh setup`

For Termux-specific issues, include:
```bash
uname -a
bash --version
pkg list-installed | grep -E 'coreutils|bzip2|binutils|netcat'
```

---

## Code Style

The codebase follows these conventions:

```bash
# Functions: snake_case
build_l01() { ... }
_internal_helper() { ... }   # leading _ = internal/private

# Variables: UPPER for globals, lower for locals
GAME_DIR="$HOME/.nexus"
local my_var="value"

# Always use local in functions
# Always quote variables: "$VAR" not $VAR
# Use [[ ]] not [ ] for conditionals
# Use $(command) not `backticks`
# Redirect errors: command 2>/dev/null || fallback
```

---

*NEXUS Wargame is built for learners who want real skills, not certificates.
Keep the bar high.*
