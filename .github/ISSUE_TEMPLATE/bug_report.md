---
name: Bug Report
about: Something is broken or behaving incorrectly
title: "[Bug] "
labels: bug
assignees: ''
---

## Platform

<!-- Select all that apply -->
- [ ] Termux (Android)
- [ ] Kali Linux
- [ ] Ubuntu
- [ ] Debian
- [ ] Arch Linux
- [ ] Other: ___________

**bash version:**
```
paste output of: bash --version
```

**NEXUS version:**
```
paste output of: bash wargame.sh 2>&1 | head -3
```

---

## Affected Level

Level number (or `setup` / `play` / `status` / `verify` if not level-specific):

---

## What Happened

**Command you ran:**
```bash

```

**Expected output:**

**Actual output:**
```

```

---

## Reproduction Steps

1.
2.
3.

Does this reproduce after a clean setup?
```bash
bash wargame.sh setup
bash wargame.sh play
```
- [ ] Yes, still broken after clean setup
- [ ] No, clean setup fixed it
- [ ] Did not try

---

## For Termux Users

```bash
# Paste output of:
uname -a
pkg list-installed 2>/dev/null | grep -E 'coreutils|bzip2|binutils|netcat|bash'
```

---

## Additional Context

<!-- Any other information that might help -->
