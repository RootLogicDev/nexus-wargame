# Security Policy

## Scope

NEXUS is a **local, offline training tool**. It runs entirely on your own device
and makes no network connections except the intentional localhost Level 14 challenge.

### In scope
- Logic flaws that allow progression bypass without solving levels
- State manipulation vulnerabilities that undermine the scoring system
- Code execution issues in the setup or game shell
- Cross-platform inconsistencies that cause incorrect behavior

### Out of scope
- The intentional Level 14 localhost TCP listener (this is a designed challenge feature)
- Environment variable injection in Level 17 (intentional challenge design)
- The fact that `~/.nexus/` is readable by the running user (by design — it's a local tool)

---

## Reporting a Vulnerability

If you find a bypass, integrity flaw, or security issue in the engine:

1. **Do not open a public GitHub issue** for security-sensitive bugs
2. Open a **private GitHub security advisory** via the Security tab
3. Include:
   - Description of the flaw
   - Steps to reproduce
   - Impact (what it allows a player to do that they shouldn't)
   - Platform and version (`bash wargame.sh 2>&1 | head -3`)

Responses within 48 hours. Fixes targeted within 7 days for critical issues.

---

## Intended Security Model

NEXUS operates on the **honor system with enforcement**:

- Passwords are SHA-256 hashed — answers cannot be read from disk
- State file integrity is protected by a machine-specific checksum
- Tampering with the state file resets all progress
- Hint counts persist across sessions — they cannot be farmed by restarting
- Time limits are enforced at submission, not just display

The system is designed to resist casual bypass attempts, not a determined adversary
with full filesystem access. It is a training tool, not a security boundary.

---

## Supported Versions

| Version | Supported |
|---------|-----------|
| v1.1.1  | ✓ Current |

