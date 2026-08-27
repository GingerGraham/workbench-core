# Troubleshooting

## `wb install` says a prerequisite couldn't be installed automatically

Install it yourself with your distro's package manager, then re-run
`wb install`. The full required list: `awk`, `sed`, `tr`, `grep`, `column`,
`git`, `curl`, `ssh-keyscan`, `ssh-keygen`. On Debian/Ubuntu, `column` is in
`bsdextrautils` (not `util-linux`, despite older docs implying otherwise);
`ssh-keyscan`/`ssh-keygen` are in `openssh-client`.

## My shell doesn't have any workbench functions after `wb install`

1. Did you start a *new* shell (or `source ~/.bashrc`)? The loader only
   runs on shell start.
2. Check the stub landed: `grep workbench ~/.bashrc`.
3. Check core is actually registered and has a `current` snapshot:
   `wb status` — if `core`'s row is missing entirely, re-run `wb install`.
4. Run the loader directly to see any error output:
   `bash -x ~/.local/share/workbench/modules/core/current/lib/loader.sh`

## A module's functions aren't loading even though `wb status` shows it registered

- Check `SYNC` in `wb status` — a module with sync disabled
  (`wb sync disable <name>`) is intentionally not re-sourced into new
  shells (ARCHITECTURE.md §3) until re-enabled: `wb sync enable <name>`.
- Check the module declares `core_api:` in its manifest — without it,
  `register:` is ignored entirely (treated as a legacy deploy-only
  manifest).
- Check the Core API version is actually compatible: a module refuses to
  register (loudly, in the sync log) if its declared `core_api:` range
  doesn't include your `CORE_API_VERSION`
  (`~/.config/workbench/core/version`).

## A `wb update` isn't picking up a new release

- `latest` and `branch:` re-check every cycle; `tag:`/`commit:` pins are
  static by design — that's the point of pinning. `wb track <name> --latest`
  to go back to auto-tracking.
- For a public repo, resolution goes through GitHub's unauthenticated API,
  which rate-limits at 60 requests/hour per IP — if you're hitting that,
  it will self-correct on the next cycle; the log will say so.

## SSH deploy key issues for a private module

- The generated public key is at `~/.ssh/workbench-<name>.pub` — make sure
  it's added to the repo as a **read-only** deploy key (write access is
  never needed and shouldn't be granted).
- Test the alias directly: `ssh -T workbench-<name>` (for GitHub, expect
  "Hi <repo>! You've successfully authenticated...").
- If you registered the module before adding the key to GitHub, just
  re-run `wb update <name>` once the key is added — nothing else needs
  re-doing.

## `wb install`'s Ansible step failed

The pure-shell bootstrap (prereqs, core registration, the loader stub)
already ran and produced a working shell *before* Ansible was invoked — an
Ansible failure here is never fatal to having a working shell. It usually
means either `ansible-core` itself needs attention (check
`ansible-playbook --version` is >= 2.14) or a module declared in
`ansible/host_vars/localhost.yml` couldn't be reached; the printed error
names which task failed.

## Modules aren't syncing automatically — I have to run `wb update` by hand

`wb install`/`wb apply` install a fixed-interval OS timer (systemd user
timer on Linux, a launchd agent on macOS) that fires `wb sync run-if-due`
every 5 minutes; the engine itself decides whether that firing should
actually do anything (see `contracts/tracking-spec.md` §Cadence). If that
timer never got installed — a container or minimal server with no active
login session has no `systemd --user` bus, which `wb apply`'s output will
report as "Could not enable/start workbench-sync.timer" rather than fail
silently — scheduled sync won't run at all. Two ways to fix it:

- Enable lingering so a user session (and its bus) exists without an
  active login: `loginctl enable-linger "$USER"`, then re-run `wb apply`.
- Or just call `wb update` (or `wb sync run-if-due`) yourself, e.g. from
  your own cron/systemd setup, or by hand whenever you want to check for
  updates — nothing else about `workbench-core` depends on the timer
  actually being installed.

## Something looks like `git` is being used where the docs say it shouldn't be

For a public repo on `latest`/`tag:`/`commit:` tracking, no `git` should
ever run — `tests/check-distribution-no-git.sh` asserts this by scrubbing
`git` from `PATH` entirely and confirming the fetch still works. If you see
`git` involved for a public repo, check whether that module is actually
`branch:`-tracked (the one deliberate exception — see
`contracts/tracking-spec.md`) before assuming it's a bug.

## I switched a module to `branch:` tracking and now have two copies of its files

Expected — see `docs/module-authoring.md`'s "Dev-mode disk duplication"
section. Your own editing clone and workbench's fetched snapshot are, by
design, two separate things.
