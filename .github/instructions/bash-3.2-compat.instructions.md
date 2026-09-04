---
applyTo: "bin/**,lib/**,bootstrap.sh,tests/**"
---

# Bash 3.2 compatibility

Files matching this scope run on a user's real machine, including
macOS's stock `/bin/bash`, which is Bash 3.2 (Apple hasn't shipped a
newer default since the GPLv3 switch). Do not use:

- Associative arrays (`declare -A`) — use an indexed array plus a
  registration/getter function pair instead. `lib/core/version.sh`'s
  `_WB_SCRIPT_VERSIONS` handling is the pattern already established in
  this codebase; follow it rather than inventing a new one.
- `${var,,}` / `${var^^}` (case conversion) — use `tr` or `awk`
  instead.
- `mapfile`/`readarray` — use a `while IFS= read -r` loop instead.
- `printf -v` with array subscripts, `wait -n`, coprocesses, or any
  other Bash 4+-only construct.

`tests/check-bash32-compat.sh` checks for some of these mechanically,
but it's not exhaustive — treat this list as the actual constraint, not
just what that one test happens to catch.

This scope does NOT include `.github/scripts/**` — see
`release-tooling.instructions.md` for that directory's (different)
rules.
