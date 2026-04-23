# 🔴 NEXUS WARGAME v1.1.1 — Operation: Zero Day

---

## 🚀 Latest Update — v1.1.1 (Integrity & Stability Upgrade)

This update focuses on strengthening the internal reliability and security of the system.

### 🔒 Core Improvements

- **State Integrity Enforcement**
  - Added checksum validation to prevent corrupted or tampered progress data

- **Execution Safety Guards**
  - Protected destructive operations (`rm -rf`) with path validation
  - Prevents accidental or unsafe file deletion

- **Cross-Platform Time Handling**
  - Replaced non-portable `date -d` usage
  - Ensures consistent timing across Termux and Linux environments

- **Signal Handling (Stability)**
  - Added `SIGINT` (Ctrl+C) trap
  - Prevents state corruption during forced exits

---

### 🧠 Why This Matters

These changes transform the system from a basic script into a **controlled and resilient training environment**.

- More stable execution  
- Reduced risk of corruption  
- Stronger anti-tamper behavior  
- Consistent performance across platforms  

---

### ⚠️ Note

This update does **not** add new levels.  
It strengthens the **core engine** to support upcoming advanced features in future versions.

---

> A hardened terminal-based cybersecurity wargame designed to simulate real-world attack workflows.

---

## ⚡ Overview

NEXUS WARGAME is a 20-level offensive security training environment that forces you to think like an operator.

No hand-holding. No predictable puzzles.

You will:
- Enumerate systems
- Extract hidden credentials
- Decode and analyze data
- Chain commands into solutions
- Operate under time pressure

---

## 🧠 Why This Exists

Most beginner wargames teach commands.

NEXUS trains:
- **Decision making under noise**
- **Pattern recognition**
- **Tool chaining**
- **Realistic problem solving**

This is closer to real-world scenarios than typical CTF-style tasks.

---

## 🎯 Skills Covered

- Linux enumeration
- File analysis & identification
- Log parsing & pattern extraction
- Encoding/decoding (Base64, ROT13, binary artifacts)
- Privilege escalation concepts (SUID, cron, env leaks)
- Networking basics (Netcat, local services)
- Command pipelines (`grep`, `cut`, `sort`, `uniq`)

---

## 🚀 Installation

```bash
git clone https://github.com/yourname/nexus-wargame
cd nexus-wargame


▶️ Usage
Bash
bash wargame.sh setup       # Build environment (run once)
bash wargame.sh play        # Start / continue
bash wargame.sh play --timed  # Timed mode
bash wargame.sh status      # View progress
bash wargame.sh leaderboard # View top scores
bash wargame.sh report      # Export completion report
bash wargame.sh reset       # Reset progress

🖥 Supported Platforms
Termux (Android)
Kali Linux
Ubuntu / Debian
Arch Linux

🎮 In-Game Commands
Inside the game terminal:

objective      View mission objective
story          View narrative context
hint           Get next hint (costs points)
submit <pw>    Submit answer
score          Show current score
achievements   View unlocked achievements
exit           Return to main menu

🏆 Progression System
20 Levels (increasing difficulty)
Dynamic scoring (efficiency matters)
Achievement system
Speedrun mode
Rank System
S-RANK — Elite
A-RANK — Expert
B-RANK — Proficient
C-RANK — Developing
D-RANK — Beginner

🧩 Example Challenges
Identify valid files among decoys
Extract credentials from logs
Decode encoded payloads
Analyze binary data
Discover hidden files
Interact with local network services
Build multi-step command pipelines

⚠️ Requirements
Make sure these are installed:
Bash
coreutils
bzip2
gawk
netcat      # required for networking level
binutils    # for strings command
🧠 Design Philosophy
Real skill comes from filtering noise, identifying patterns, and chaining simple tools into effective solutions.

📜 License
MIT License
⭐ Support
If you find this project useful or challenging:
⭐ Star the repository
🍴 Fork and improve it
🐛 Report issues

🔥 Roadmap
Online leaderboard
Additional advanced levels
Red-team simulation scenarios
Web-based interface

