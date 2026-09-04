---
applyTo: ".github/scripts/**"
---

# Release/CI tooling — not Bash 3.2 constrained

Everything under `.github/scripts/` runs only on GitHub-hosted
`ubuntu-latest` runners — never sourced by `lib/loader.sh`, never
shipped to a user machine. Bash 4+ features are fine here.

By convention (not requirement) this directory still avoids
associative arrays, matching `lib/core/version.sh`'s
indexed-array-plus-getter-functions pattern — see
`.github/scripts/release/compute-bumps.sh`'s
`FILE_SEV_ENTRIES`/`_file_sev_get`/`_file_sev_set` for the existing
example. Match that style for consistency if you're extending this
directory, but don't treat the Bash 3.2 constraint itself as applying
here — it doesn't.

`.github/scripts/release/lib.sh` is the shared library for Conventional
Commit parsing, bump arithmetic, and the CHANGELOG `[Unreleased]` gate
— read it before adding a second implementation of any of that.
