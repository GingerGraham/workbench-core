# workbench — decomposition & contract plan

Status: **plan only**, no code written yet. Grounded in the current `dotfiles`
repo (`v1.9.2`, freezing at `v1.10.0`) and its clone `workbench-precursor`.
All open decisions (D1–D9) resolved — see `docs/decisions-log.md`.

This is the standing technical reference for the `workbench` decomposition —
committed to `workbench-precursor` (root: `ARCHITECTURE.md`, historical
reference only), and living at `docs/architecture.md` in `workbench-core`,
the authoritative copy. Read this before proposing anything that touches
repo structure, the manifest schema, the sync engine, or the
distribution/tracking model. Decisions are logged separately in
[`docs/decisions-log.md`](decisions-log.md) — add a new entry there when
something here changes rather than letting implementation drift from it.
The Claude Project's own instructions stay short and point here rather than
duplicating it.

---

## 1. Guiding principles

These fell out of the current codebase's own conventions and Graham's stated
constraints — carried forward deliberately rather than invented fresh:

1. **Engine-computed destinations, not author-supplied ones, wherever trust matters.** `dotfiles` already does this for clone paths (`external_synced_repos` has no `clone_dir` field) and state files. `workbench-core` extends the same principle to shell registration (§5).
2. **Idempotency is a property of every action, not an artifact of the tool.** Ansible gives this for free today; if it's dropped, everything it currently buys has to be reimplemented explicitly — not assumed away.
3. **Additive compatibility over version bumps.** A schema/contract change is only "breaking" if it cannot be expressed as an optional, ignorable key. Bump numbers exist for when that genuinely isn't possible.
4. **One generalised engine, not parallel special cases.** `dotfiles` currently runs two independent sync engines (self-sync for the repo itself, `sync-external` for add-ons) with different cadences and code paths. `workbench-core` collapses this: core is "module zero," syncing itself through the same engine every other module uses. The same principle governs profiles/bundles (§10) — a bundle is sugar over the engine, never a special-cased branch inside it.
5. **Unknown things fail loud, not silent.** Matches the existing manifest validator's posture (`dest` denylist violations fail the run and name the offending path) — a module `workbench-core` can't understand should refuse to load, not degrade quietly.
6. **No persistent, incrementally-mutated state for ordinary use.** The default, production path for consuming any tracked content — core, an ecosystem module, or an independent tool — never leaves a live, `git pull`-updated working copy on a user's machine. Content is fetched as an immutable, atomic snapshot and swapped in whole. A persisted, incrementally-updated `git` working tree exists **only** as a deliberate, opt-in developer activity (§9.1) — never as an artifact of ordinary tracking, regardless of whether the underlying repo is public or private.

---

## 2. Repo topology

Two structurally different kinds of add-on live in this ecosystem, and the
distinction matters for naming, visibility, and how they're pitched — even
though the manifest contract (§5) and sync engine (§9) treat them
identically:

- **Ecosystem modules** — `workbench-git`, `workbench-gpg`, `workbench-ssh`,
  `workbench-shell`, and future modules in the same family. These are
  meaningless standalone: `workbench-git` makes no sense without
  `workbench-core` underneath it. Always `workbench-`-prefixed, always
  public, deeply integrated via `register:` (helper functions, shell
  config, getters).
- **Independent tracked tools** — `awsconfd`, `nvim-config`, `ai-config`,
  and future tools in the same shape. Fully usable standalone, with no
  dependency on `workbench-core` at all — but can *optionally* hook into
  the same sync/deploy/tracking mechanism to ride along with the rest of
  the ecosystem. Arbitrary naming (no `workbench-` prefix expected), and
  need genuine public/private flexibility — see §9.1 for how private
  tracking works for this tier.

| Repo | Purpose | Visibility | Priority |
|---|---|---|---|
| `dotfiles` | Frozen at `v1.10.0`. No further feature work. Wave 2 deprecation notice only, per the existing freeze plan. | Public (unchanged) | Already decided — no action from this plan |
| `workbench-precursor` | Scratch workspace only. Donates code to the repos below, then is archived (D3). Not a long-term repo. | Private (unchanged) | Retire once §3 extraction is complete |
| `workbench-core` | Engine: loader, contracts, prerequisites, module registration, distribution & tracking (§9), the known-modules catalog and bundle definitions, and ships the `wb` CLI — see §10. | **Public** | **P0** |
| `workbench-git` | Git identity/project-context management (current `roles/git` + `tools/git.sh`). | Public | P1 |
| `workbench-gpg` | GPG key lifecycle (current `tools/gpg.sh` + `lazy/gpg-management.sh` + `docs/gpg.md`). | Public | P1 |
| `workbench-shell` | Opinionated shell layer: prompt/starship, tmux, vim, core aliases, bash/zsh-specific tweaks. | Public | P1 |
| `workbench-ssh` | Opinionated SSH layer: multi-forge known-hosts pre-trust beyond what's actively used, hardened client defaults, agent `IdentityAgent` routing (current `roles/ssh` + `core/ssh.sh`). Confirmed separate module (D1) — the bootstrap-critical subset stays in core, see §3. | Public | P1/P2 |
| `workbench` | **TUI only.** Front-end for the `wb` CLI shipped by `workbench-core` — not an engine, not a separate command surface. | Public from the start | P3 — build after core + 2–3 real modules are stable (Wave D) |
| `awsconfd` | Independent tracked tool — already exists, working. First real-world validation of the manifest contract (§5) and the tracking model (§9). | Public or private, author's choice — private path uses deploy keys (§9.1) | Migrate manifest in Wave C |
| `nvim-config`, `ai-config` | Independent tracked tools — opinionated configuration for existing third-party tools, usable standalone or hooked into sync. | Public or private, author's choice | Not required for MVP |
| `workbench-devtools` (or per-tool: `workbench-terraform`, `workbench-golang`) | Terraform/OpenTofu aliases, AWS/Azure tooling, install-* functions for dev tools. | Public | P4 — not required for MVP |

No repo is renamed and no existing repo is deleted as part of this plan.
`dotfiles` stays exactly where it is, doing exactly what it does today.
Windows/PowerShell is explicitly out of scope for all repos above (D4) —
this is a Linux/macOS/WSL2 ecosystem, matching `dotfiles`' current reach.

---

## 3. Decomposing the monolith

Mapping current `dotfiles` pieces to target repos:

| Current location | Target | Notes |
|---|---|---|
| `shell/config/loader.sh` (tier system) | `workbench-core` | Rewritten as **multi-root** — see below, this is the single largest architectural change |
| `shell/config/core/functions.sh` (elevation, distro/OS/arch detection, `get-functions`, getter-registry pattern) | `workbench-core` | Getter registry becomes manifest-driven (§5), not hardcoded. `WORKBENCH_ARCH` is a new fact added here (§4) |
| `shell/config/core/aliases.sh` | `workbench-shell` | Not core — these are opinionated, not structural |
| `shell/config/core/ssh.sh` (agent helpers, `list-ssh-hosts`) | `workbench-ssh` | Opinionated layer — confirmed separate (D1) |
| SSH deploy-key generation + `config.d` alias writing (today: `install.sh` Phase 3) | `workbench-core` | **Not** part of `workbench-ssh` — this is bootstrap-critical for *any* private repo, including private independent tools' deploy-key path (§9.1). Gated exactly as today: skipped entirely if nothing private is registered. |
| `shell/config/distro/*.sh`, platform detection | `workbench-core` | Every module needs distro/OS/arch facts; this is load-bearing infrastructure |
| `shell/config/lazy/user-extensions.sh`, `DOTFILES_USER_EXT_DIR` | `workbench-core` | Renamed `WORKBENCH_USER_EXT_DIR`, same last-loaded/shadowing semantics |
| `shell/config/tools/git.sh`, `ansible/roles/git/` | `workbench-git` | Manifest-driven project/context system is a strong existing design — port as-is. **Exception:** `_read_prompt` extracts into `workbench-core`'s Core API surface (§6) — it does not travel with the rest of this file |
| `shell/config/tools/gpg.sh`, `shell/config/lazy/gpg-management.sh` | `workbench-gpg` | No Ansible role today (interactive shell functions only) — stays that way |
| `shell/config/tools/terraform.sh` | `workbench-devtools` | Or its own repo later — not urgent |
| `shell/config/lazy/installers*.sh`, `_managed_tools_registry` | Split: framework in `workbench-core`, entries travel with their owning module | See §5 — registries become per-module manifest declarations, not one hardcoded file |
| `ansible/roles/sync`, `ansible/roles/sync-external`, `scripts/external-sync.sh`, `scripts/sync.sh` | `workbench-core` | Unified into one engine — core-self and modules both run through it (principle 4), rebuilt around the distribution/tracking model in §9 |
| `install.sh` (prereqs, host_vars generation, SSH deploy keys) | `workbench-core` | Becomes the `wb` CLI's `install`/`apply` subcommands; prereq phase gains the missing checks (§7) |
| `docs/*.md` | Split per target repo | Each module repo owns its own docs; core owns the contract docs (this file's descendants) |

### The multi-root loader — the change everything else depends on

Today, `get-functions` and `loader.sh` both assume a **single** config root
(`SHELL_CONFIG_DIR`, a symlink into the one `dotfiles` working tree) plus one
flat user-extension directory. That assumption breaks the moment shell
config is split across `workbench-core` + `workbench-git` + `workbench-gpg` +
`workbench-shell` + `workbench-ssh`, each cloned to its own path.

`workbench-core`'s loader must instead:

1. Enumerate every **registered, sync-enabled** module's state directory (§5/§9).
2. For each, read that module's `register.list` (flattened from its manifest's `register.shell[]` entries at sync time — same "flatten YAML into a shell-readable list" pattern the current `deploy.list`/`hooks.list` already use).
3. Source each declared file into the tier its manifest specifies (`env` / `core` / `tools` / `platform` / `distro` / `lazy`), in the same tier order `loader.sh` already enforces today.
4. Run `WORKBENCH_USER_EXT_DIR` last, as today.

`get-functions` generalises the same way: instead of one glob root, it walks
every registered module's declared files, and the getter registry (§5) is
built from what modules *declare*, not a hardcoded list in `functions.sh`.
This rewrite must not depend on bash-4+ features (`shopt -s globstar`,
`declare -A`, `mapfile`) — see §7's bash 3.2 compatibility gap.

---

## 4. `workbench-core` responsibilities checklist

Mapped against the brief, with what already exists as precedent vs. what's genuinely new:

| Requirement | Precedent in `dotfiles` | What's new in `workbench-core` |
|---|---|---|
| Idempotent actions | Ansible modules, `deploy_copy_file`'s existence-check, `record_applied_state.yml`'s sha stamping | Same discipline, generalised to a single engine (principle 4) |
| Interface contracts for extensible modules | None — `.dotfiles-sync.yml` covers *sync/deploy* only, never shell integration | §5 — the manifest contract, this is the core deliverable |
| Ensure folders in place | `common` role's `common_xdg_dirs` | Generalised: core owns its own base dirs; modules can request extra ones via manifest, same `mkdir -p` discipline `external-sync.sh` already uses |
| Baseline prerequisites incl. minimal distros (Fedora WSL missing `awk`) | `check_prereqs()` checks git/python3/ansible-core only. **`awk` is never checked despite being a hard dependency** (`dedupe-path`, `_read_external_repos_from_host_vars`) | New prerequisite phase — see §7, this is a confirmed real gap, not speculative |
| Read/ingest N extension files from a known directory | `DOTFILES_USER_EXT_DIR` glob (single dir, hand-authored only) | Generalised to N *module* directories, engine-populated from manifests (§3) |
| Common interfaces: read/prompt, sudo/run0, getters, platform facts | `sudo-test`, `get-elevation-command`, `elevate-cmd`, `_read_prompt` (git.sh), the getter-registry pattern, `DOTFILES_OS`/`DOTFILES_DISTRO`/`DOTFILES_WSL`/`DOTFILES_SHELL` | Lifted into core as the Core API surface (§6), **plus a new fact: `WORKBENCH_ARCH`** (raw `uname -m`) — currently absent entirely; `uname -m` detection and arch-name mapping is duplicated ad hoc across at least seven installer functions in the donor codebase (`_aws_arch`, `_edit_arch_stem`, the fzf/jq/yq/tenv/neovim installers, `_op-install-binary`), each with its own case statement. Core exposes the raw fact once; a documented normalization snippet in `module-authoring.md` covers the differing per-tool naming conventions (Go-style `amd64`/`arm64` vs. uname-style `x86_64`/`aarch64`) rather than a universal mapper, since no single mapping satisfies every upstream tool |
| Installer for core | `install.sh` | Becomes `wb install` / `wb apply`, same prereq → host-state → apply shape (§10) |
| Add extension without full reinstall | **Does not exist today** — adding a repo to `external_synced_repos` requires a full Ansible re-run | New: `wb add <n> [url]` — hot-path, see §9/§10 |
| Optional sync, core and modules independently | One flag (`dotfiles_sync_enabled`) gates *both* self-sync and all of `sync-external` together — no per-repo toggle exists | New: per-module `sync.enabled`, independent of core's own toggle — see §9 |
| Version/ref tracking (branch vs. tag vs. release) | **Does not exist** — only a single tracked branch + a suspend flag (`GIT_BRANCH`/`DEV_MODE`) | New: the four-state tracking model, §9.2 |
| Non-git production distribution | Exists for `dotfiles` self-sync only (`docs/sync.md`'s "release mode" — commit-based, not tag-based, GitHub-API-plus-tarball, atomic symlink swap) | Generalised to every module, core included, and re-based on tags rather than commits — §9.1 |

---

## 5. The extension manifest & contract

### 5.1 The actual root cause of the current gap

Worth stating precisely, since it explains why `register:` (below) has to be
engine-routed rather than author-specified: `sync-external`'s `dest`
denylist blocks writes to **both** `~/.config/shell/` and
`~/.config/dotfiles/` (which is where `DOTFILES_USER_EXT_DIR` lives). That
denylist is correct and should stay — but its side effect is that **no
manifest-driven module can ever land shell code anywhere the loader or
`get-functions` will find it.** `awsconfd`'s functions aren't missing from
`get-functions` by oversight; they're structurally unreachable under the
current contract. This is the gap `register:` closes.

### 5.2 Schema — additive, two supported filenames

`.dotfiles-sync.yml` stays the filename and `version: 1` the sync/deploy
identifier for it, permanently, exactly as originally documented here — a
legacy `dotfiles` machine reading it behaves exactly as it does today, and
`version: 1` manifests are already required to tolerate unknown top-level
keys per the existing spec ("Unknown top-level keys... are ignored, not
fatal"). This means **existing module repos need zero changes to keep
working**, and Graham's own `awsconfd` manifest can gain the new keys
without breaking any machine still on `dotfiles`.

`workbench-core` also discovers a second, parallel spelling —
`workbench.yml` / `workbench.yaml` / `wb.yml` / `wb.yaml`, checked in that
order ahead of `.dotfiles-sync.yml` — which must declare `version: 2` and
carries the identical, already-additive field set below. Filename and
`version:` are a bound pair, enforced both at the developer-time validator
and at the sync engine's own D30 refusal gate. This reopens what this
section originally said ("same filename, permanently") — see
`docs/decisions-log.md` D46 for the full decision and rationale, including
why legacy compatibility was never actually at stake.

```yaml
# .dotfiles-sync.yml — unchanged version, additive keys
version: 1
branch: main                 # default TRACK_REF only — see §9.5. Machine-side
                              # tracking state, once it exists, always wins.

deploy:                      # unchanged — identical semantics to today
  - src: shell/
    dest: ~/.local/share/workbench/modules/awsconfd/src/   # engine-computed convention, see note below
    mode: copy

# ── everything below is new, optional, workbench-core only ──────────────────
core_api: ">=1.0 <2.0"       # required for register: to be honoured; ignored by legacy dotfiles
sync:
  enabled: true               # per-module opt-out, default true, overridable in host state (§9)

register:                     # THE fix for the functions/aliases gap
  shell:
    - src: shell/aws.sh       # path within repo, relative — validated identically to deploy[].src
      tier: tools             # env | core | tools | platform | distro | lazy — maps to loader tiers
  installers:
    - src: shell/installers.sh
  getters:                    # optional — populates the generalised get-functions registry (§3)
    - name: aws
      function: get-aws-functions
      label: "AWS config helpers"

hooks:                        # unchanged
  post_deploy: {...}
```

`register.shell[].dest` is deliberately **absent** — the engine computes it
(`${WORKBENCH_HOME}/modules.d/<module-name>/<basename>`), the same
engine-computed-destination principle that already governs clone paths. This
removes the injection surface `deploy[].dest` has to defend against with a
denylist — a `register:` entry structurally cannot target anything outside
its own module namespace, so no denylist is needed for it at all.

### 5.3 Field reference (new keys only)

| Field | Required | Default | Meaning |
|---|---|---|---|
| `core_api` | no | — | Semver range this module targets. Absent = treated as deploy/sync-only (legacy behaviour); `register:` is ignored without it. |
| `sync.enabled` | no | `true` | Module-level opt-out. Machine-side state can further override — see §9. |
| `register.shell[].src` | yes, per entry | — | Path within repo, validated like `deploy[].src`. |
| `register.shell[].tier` | no | `tools` | Loader tier — governs load order. Only `platform`/`distro` are conditionally sourced (by host match); every other tier, `lazy` included, is sourced unconditionally on every shell start. |
| `register.installers[].src` | no | — | Files scanned for `install-*` functions, folded into the generalised tool registry. |
| `register.getters[]` | no | — | Declares a domain getter (`get-<n>-functions`) so `wb functions` can enumerate it without a hardcoded registry. |

Unknown keys under `register:` are ignored, not fatal — same forward-compatibility posture as the rest of the spec.

### 5.4 Compatibility boundary — what would actually be breaking

The additive approach above covers everything currently in scope. A genuine
break would only be needed for something like: changing `dest` validation
semantics incompatibly, making `register:` *mandatory*, or supporting
multiple manifests per repo. `version: 2` is now spoken for by §5.2 and
`docs/decisions-log.md` D46's filename change, so a **future** genuine schema break needs
`version: 3` (or whatever the next integer is at that time) — and, per D46's
own precedent, that decision must explicitly say whether the break also
pairs with a new filename or stays on the existing `workbench.yml`-family
names, rather than assuming either. `workbench-core` treats a manifest
declaring a version its running core doesn't support as "this repo isn't
syncable by this core," and refuses to sync it loudly rather than guessing.
Nothing in the current plan requires this — flagged here only so the escape
hatch is defined before it's needed.

---

## 6. Version taxonomy — the Core API contract

Per the earlier design decision: three independent integers, each checkable
in portable shell before any core library is guaranteed loadable (no `awk`,
no functions, no sourcing required to read them):

```
# ~/.config/workbench/core/version — plain KEY=VALUE, readable via source or grep
CORE_API_VERSION=1.1
MANIFEST_SCHEMA_VERSION=1
STATE_SCHEMA_VERSION=2   # bumped from 1 — see D23 (installers.list, additive)
WORKBENCH_CORE_SEMVER=0.1.0
```

- **`CORE_API_VERSION`** — the function/variable contract core exposes to
  modules: `elevate-cmd`, `get-elevation-command`, `_read_prompt`, the
  platform-fact block (`WORKBENCH_OS`, `WORKBENCH_DISTRO`, `WORKBENCH_WSL`,
  `WORKBENCH_SHELL`, `WORKBENCH_ARCH`), the registration directory layout,
  and the tracking-variable contract (`WORKBENCH_TRACK_<MODULE>`, §9.5).
  Carries `X.Y` minor-version granularity, not a bare integer — see
  `docs/decisions-log.md` D29 for the bump policy. A module declares `core_api: ">=1.0 <2.0"` in its manifest; core checks
  this **before** sourcing any of that module's `register.shell[]` files,
  and refuses (loud warning, not a silent skip) rather than sourcing
  something that may call an undefined function. Shell scope for this
  contract is bash + zsh only, matching `dotfiles`' current reach and
  requiring bash 3.2 compatibility (macOS default) throughout — no
  bash-4+-only constructs anywhere in the Core API library.
- **`MANIFEST_SCHEMA_VERSION`** — the `.dotfiles-sync.yml` structure itself (§5).
- **`STATE_SCHEMA_VERSION`** — the on-disk state layout (`sync.conf`,
  `deploy.list`, `register.list`, `hooks.list`, `manifest-hash`, the
  `snapshots/` tree — §9.3). Bump when this shape changes in a way that
  needs migration.

These are independent on purpose — a new Core API function doesn't require a
manifest or state change, and vice versa.

### 6.1 Three version concepts (bootstrap-fix brief §5)

The contract versions above are one of **three** independent, deliberately
decoupled version concepts in this codebase — a later reader who sees a bare
"version" mentioned somewhere should be able to tell which of the three it
means:

| Concept | Shape | Where it lives | Purpose |
|---|---|---|---|
| **Contract versions** (`CORE_API_VERSION`/`MANIFEST_SCHEMA_VERSION`/`STATE_SCHEMA_VERSION`) | small integers | `~/.config/workbench/core/version` | compatibility gating between core and modules — §6 above |
| **Release/tag version** | `vX.Y.Z`, matches the git tag | `VERSION` file, repo root | "which release of `workbench-core` is this checkout" |
| **Script-local version** | `X.Y.Z`, one per file | inline constant, registered via `workbench_register_script_version()` (`lib/core/version.sh`) | "which version of *this specific file* produced this output" — independent of the release tag, bumped by that file's own author on its own schedule |

The release version is read by `workbench_release_version()`, which reads
the repo-root `VERSION` file relative to wherever `lib/core/version.sh` is
actually running from — this works identically for a developer's git clone
or a fetched snapshot, since both are the full repo tree with `VERSION` at
the root, no special-casing needed. `VERSION` is bumped as the last commit
before cutting a tag (or the same commit), so the file and the tag never
drift apart.

The script-local registry is a plain indexed array
(`_WB_SCRIPT_VERSIONS`, `path|version` entries), not a same-named variable
repeated per file — `bin/wb` sources on the order of twenty files into one
shell process, and a repeated variable name would get clobbered file-to-file
(or throw outright if `readonly`). This is the same pattern already
established for `_WB_SHELL_PREREQS_REQUIRED` in `lib/core/prereqs.sh`, not a
new convention. `wb version` surfaces both the release version and the full
registered-script-version list; `wb install`/`wb apply` print the release
version once at the start; hot-path operations (`wb update`,
`sync run-if-due`, the loader on every shell start) log it only at
`log_debug`, gated by `WORKBENCH_DEBUG`.

---

## 7. Addressing missing components

Confirmed gaps, with the fix each maps to:

1. **`awk` (and friends) never checked as a prerequisite.** `check_prereqs()` in `install.sh` checks only `git`, `python3`, `ansible-core`. `awk` is a hard dependency of `dedupe-path()` and the host-vars YAML reader, and is confirmed absent on minimal Fedora WSL images. `wb install`'s prereq phase must enumerate every external binary any Core API function calls (`awk`, `sed`, `tr`, `grep -E`, `column`, `git`, `curl`, `ssh-keyscan`, optionally `gpg`, `unzip`, `zip`) and check/install all of them, not just the three checked today.
2. **No mechanism for a module to register shell functions/aliases.** Root-caused in §5.1, fixed by `register:`.
3. **Sync is all-or-nothing.** One flag gates both self-sync and every external repo together. Fixed by per-module `sync.enabled` + independent core toggle (§9).
4. **No hot-add path.** Registering a new module today requires a full Ansible re-run. Fixed by `wb add`/`wb remove` (§9/§10) — but see the convergence constraint in §8.
5. **No module removal story is formalised.** `dotfiles` has partial coverage for renaming/removing a sync destination; `wb remove <n>` needs to be a first-class command with the same idempotent-cleanup discipline as everything else, not a manual doc procedure.
6. **The getter/tool registries are hardcoded, not extensible.** `_function_getters_registry`, `_managed_tools_registry` etc. are fixed lists inside `dotfiles` itself. Fixed by `register.getters[]`/`register.installers[]` (§5).
7. **No Core API compatibility check exists at all today** — there's no version to check against. Fixed by §6.
8. **Profile concept doesn't map cleanly onto a modular world.** Resolved (D2) — see §10.
9. **No SSH bootstrap capability independent of the SSH module.** Fixed — bootstrap-critical deploy-key/alias mechanics live in core, not `workbench-ssh` (D1, §3).
10. **CPU architecture detection is duplicated, not centralised.** At least seven installer functions in the donor codebase each independently call `uname -m` and maintain their own arch-name mapping. Fixed by a single `WORKBENCH_ARCH` fact (§4/§6); each installer's own naming-convention mapping stays local (no universal normalizer — see §4) but the raw detection call is no longer duplicated.
11. **`get-functions`' current implementation is not bash-3.2-safe.** It uses `shopt -s globstar` for recursive globbing — globstar was introduced in bash 4.0 and is silently a no-op (or a shell error, depending on context) on bash 3.2, which is what macOS ships by default. This must be rewritten using `find` (or an equivalent bash-3.2-safe traversal) as part of the multi-root loader rewrite (§3), not ported forward as-is. A dedicated test should grep `lib/` for bash-4+-only constructs (`declare -A`, `mapfile`/`readarray`, `shopt -s globstar`, `${var,,}`/`${var^^}`, `declare -n`) so this class of regression can't creep back in silently.
12. **No version/ref tracking beyond a single branch + suspend flag.** `GIT_BRANCH`/`DEV_MODE` is the entire tracking vocabulary today — no tag, release, or commit pinning exists anywhere. Fixed by the four-state tracking model, §9.2.
13. **The only non-git distribution path (`dotfiles`' self-sync "release mode") is self-sync-specific, commit-based, and not generalised.** It resolves `main`'s latest commit via the GitHub API rather than tracking tags, and only applies to the self-sync engine, not `external-sync`/the module engine. Fixed and generalised by §9.1 — tag-based, applies to core and every module identically.

---

## 8. Installer approach — Ansible vs. custom

Recommendation stands: **don't drop Ansible wholesale — split by what
actually runs unattended.**

- `dotfiles` already draws this line implicitly: Ansible renders configuration
  *once per apply*; the code that runs forever after (timers, sync, drift
  detection) is already pure shell (`scripts/external-sync.sh`,
  `scripts/sync.sh`) with zero Ansible/Python dependency at runtime. That
  split is worth keeping and making explicit as a rule, not an accident:
  - **`wb install` / `wb apply`** (one-time or occasional convergence, run
    by a human, sudo may be needed) — Ansible stays here. This is exactly
    the well-tested muscle it's good at (idempotent templating, file/symlink
    state, `--check` dry-runs), and the prereq cost (`python3 >= 3.9`,
    `ansible-core >= 2.14`) is paid once, deliberately, not on every shell
    start or sync tick.
  - **Everything that runs unattended or hot** (timers, `wb add`, `wb track`,
    `wb update`, drift checks, the loader itself) — stays pure POSIX-ish
    shell, zero Ansible/Python dependency, exactly as `external-sync.sh`
    already proves is viable for the deploy step specifically.
- The target audience being technical (your stated reasoning for tolerating
  Ansible) applies to the install-time step, where a human is present and can
  read `--check --diff` output. It applies less to the always-on background
  path, which should stay dependency-light regardless of audience.
- **Convergence constraint on the hot path:** `wb add` must write a strict
  subset of what a full `wb apply` run would produce for the same input, so
  a later full apply is always a no-op against it. This is what keeps the
  hot path from becoming a second, divergent source of truth.
- **Ansible never re-implements fetch or deploy logic — it invokes the
  shared engine.** This already holds for the deploy step today (`repo.yml`'s
  initial-deploy task runs the exact script the timer runs, per its own
  comment: "Ansible never re-implements the deploy loop itself"). It now
  extends to the fetch/distribution step too (§9.1): Ansible's job during
  `wb install`/`wb apply` is to render `sync.conf`/tracking state and then
  invoke the same fetch-and-deploy engine the timer uses for the initial
  pull — it does not independently re-implement tarball resolution or
  shallow-clone-and-discard logic in Ansible tasks.

---

## 9. Distribution & sync model

Single generalised engine (principle 4). Core is "module zero," syncing
itself through the identical mechanism every module uses.

### 9.1 Distribution mechanism

Per principle 6, the default/production path never leaves persistent,
incrementally-mutated `git` state on a user's machine — content is fetched
as an immutable snapshot and atomically swapped in. `git`, where it appears
at all, is invoked as a one-shot fetch tool, never as a live, `pull`-updated
working copy — with one deliberate, opt-in exception (dev tracking, below).

- **Production tracking** (`latest` / `tag:` / `commit:` — §9.2) resolves
  the ref to a specific commit, then fetches an immutable snapshot:
  - **Public repo:** no `git` involved at all. Ref resolution via GitHub's
    (unauthenticated) API, artifact fetch via GitHub's tarball/codeload
    endpoint. This covers every ecosystem module and any independent tool
    that stays public — the overwhelming majority of the ecosystem.
  - **Private repo** (independent tools only, by author's choice — no
    `workbench-*` repo is ever private, §2): GitHub does **not** support
    the `git archive --remote` protocol (verified — GitLab does, GitHub
    explicitly doesn't), so there is no non-`git` path to private content.
    The mechanism is a shallow, single-ref `git clone --depth 1` into a
    scratch directory via the SSH deploy key already provisioned for
    bootstrap (§3), followed by extracting the working tree and discarding
    the `.git` directory entirely. No incremental pull, nothing persisted
    — same atomic-snapshot outcome as the public path, `git` used purely
    as transport. This is the one narrow, documented exception to "`git`
    only touches the dev pathway": it's a necessity of GitHub's platform
    limitations, not a design choice, and it produces zero live git state
    either way.
- **Dev tracking** (`branch:` — §9.2) is the one case that's `git` by
  design, per explicit requirement. Mechanically it's the *same*
  shallow-clone-and-discard primitive as the private-repo production case
  above (works identically for public or private repos), just re-run on
  every sync cycle so a branch's moving tip is picked up fresh each time.
  It is **not** the developer's own editing clone — that lives and is
  managed entirely outside anything `workbench` tracks (§9.6).
- Every fetch, regardless of pathway, lands in
  `snapshots/<ref-slug>-<shortsha>/` (§9.3), immutable once written, with
  `current` flipped to it via an atomic symlink swap. Old snapshots are
  pruned beyond a small retention window — the same pattern `dotfiles`'
  existing self-sync release mode already uses, generalised to every
  module.

### 9.1a Bootstrap: the initial fetch (bootstrap-fix brief)

§9.1 above specifies the *ongoing* sync mechanism — it deliberately doesn't
say how `workbench-core` gets onto a machine that has nothing installed yet,
before any of that engine code exists locally to run at all. That gap is
closed here: **`bootstrap.sh`** (repo root) is the canonical, documented
production entry point —

```sh
curl -fsSL https://raw.githubusercontent.com/GingerGraham/workbench-core/main/bootstrap.sh | bash
```

— curl + tar, no `git`, resolving the latest release tag the same way §9.1's
public-repo path does, fetching straight into the real
`snapshots/<ref-slug>-<shortsha>/` path (never a scratch/temp directory —
a tmp-cleaner sweep or reboot could silently delete `current`'s target
otherwise, breaking the loader with no obvious cause days later), writing
core's own `sync.conf`, and handing off to `bin/wb install`. A developer
working on `workbench-core` itself uses a real `git clone` +
`./bin/wb install` instead (§9.6's dev-tracking pathway, for core rather
than an ecosystem module) — that path is correct as-is and isn't going
away, it's just no longer what the docs lead with.

`bootstrap.sh` cannot depend on anything under `lib/` — none of that code
exists locally until bootstrap fetches it — so its ref-resolution and
tarball-fetch logic is a small, deliberate, accepted duplication of
`lib/distribution/resolve.sh`/`fetch-tarball.sh` and
`lib/distribution/snapshot.sh`'s slugify routine, the same narrow-exception
precedent as the private-repo git-as-transport case in §9.1/D5. It stays
deliberately tiny (get *just enough* on disk to hand off to
`bin/wb install`, nothing more) and cross-references the files it
duplicates from, and vice versa.

`bootstrap.sh` also falls back to `main` when no `vX.Y.Z` tag exists yet —
not just a bring-up convenience: without it, bootstrap is unconditionally
broken until the first tag is cut. This fallback is permanent, not removed
once a release exists.

**Deliberate asymmetry:** unlike every module `workbench-core` fetches,
`bootstrap.sh` itself is hosted unversioned, at `main` — it has no
persistent state of its own to drift, since it either succeeds once (then
hands off to the real, tag-tracked engine) or doesn't run again. Tag-pinning
it the way modules are tag-pinned would just mean an old bootstrap fetching
a new engine, buying nothing.

### 9.2 Tracking model

Four states, persisted per module as `TRACK_MODE`/`TRACK_REF`:

| `TRACK_MODE` | Behaviour | Auto re-checked? |
|---|---|---|
| `latest` (default) | Newest tag matching the format contract below | Yes, every sync cycle |
| `branch:<name>` | Branch tip — the dev pathway (§9.1) | Yes, every sync cycle |
| `tag:<name>` | Exact tag, clean or pre-release | No — static until explicitly changed |
| `commit:<sha>` | Exact commit | No — static until explicitly changed |

**Tag format contract:** tags matching `X.Y.Z` or `vX.Y.Z` (three-segment,
an optional single leading `v`, no pre-release or build metadata)
participate in `latest` resolution. Non-conforming tags are simply
invisible to `latest` resolution — not an error, just not counted.
Comparison already normalises away a leading `v` (`_wb_semver_cmp`), so a
repo whose tagging convention changes mid-history — bare before,
`v`-prefixed after, or the reverse — still resolves and sorts correctly
across the transition. See `docs/decisions-log.md` D66, amending D6. This
is published now as the contract every
module author must follow to be `latest`-trackable; formal validation of
compliance is deferred to the future extension-validation work (out of
scope here). Pre-release/RC-style tags (`v1.2.4-rc2`) are fully valid
*inputs* to an explicit `tag:` pin — useful for exactly the "test this
specific candidate" workflow — they're just excluded from the automatic
`latest` chain.

**Semver comparison is pure bash, bash-3.2-compatible, no external
dependency beyond what's already assumed** (no `sort -V`, no `python3`, no
`awk` version-sort tricks). Generalise `install.sh`'s existing `version_ge()`
pattern into a shared, tested Core API function rather than reinventing
comparison logic per call site.

### 9.3 State layout

Single root, replacing today's scattered `~/.config/dotfiles/`,
`~/.config/shell/`, `~/.config/external-sync/`, etc.:

```
${XDG_DATA_HOME}/workbench/modules/<name>/
├── sync.conf                    # TRACK_MODE, TRACK_REF, resolved SHA, sync.enabled
├── snapshots/
│   └── <ref-slug>-<shortsha>/   # immutable, one dir per fetched artifact — same
│                                 # shape whether the ref is a tag, commit, or branch
├── current -> snapshots/<ref-slug>-<shortsha>
└── deploy.list / register.list / hooks.list / manifest-hash / last-sync
```

Core itself occupies `<name> = core` — no special-cased directory shape.

### 9.4 Cadence

One shared timer (principle 4 continues to hold — this is **not** true
per-module differential cadence, which stays a deferred future enhancement).
The timer's own firing interval is dynamic:

- **Default/production interval: weekly.** Chosen partly to stay
  comfortably clear of GitHub's unauthenticated API rate limit (60
  req/hour) at any realistic personal scale — worth documenting as a known
  constraint, not something to pre-engineer around further unless it
  actually becomes a problem.
- **Drops to 5 minutes, globally, for as long as at least one registered
  module (core included) is on `branch:` tracking.** Reverts to weekly once
  nothing is. This is the direct fix for the usability regression flagged
  during design: without it, simplifying to a single shared mechanism would
  have broken the fast, low-friction feedback loop developers had under the
  old "your repo IS the shell config" model. `tag:`/`commit:` pins don't
  trigger the fast interval — changing one is a deliberate, explicit act
  that's ordinarily paired with an immediate manual trigger anyway (below),
  so there's no automatic-recheck benefit to speeding up the timer for
  them.
- **Manual, on-demand trigger** (`wb update [<name>]`) is always available
  regardless of cadence or tracking mode — confirmed in scope.
- **Release cooldown for unattended `latest` adoption (security review H3
  tier 2; docs/decisions-log.md D77).** An unattended (`scheduled`) cycle
  adopts a newly-resolved `latest` release only once it has been
  continuously resolved for `RELEASE_COOLDOWN_DAYS` (`scheduler.conf`,
  default 3 days; `0` disables) — first-seen time on the host, no remote
  timestamps or extra API calls. `wb update`/`wb add`/`wb track` adopt
  immediately regardless; `branch:`/`tag:`/`commit:` modes are unaffected.
  A local, append-only `adoption.log` records what was adopted, held in
  cooldown, or ran a hook, and when — for incident response, not
  telemetry.

### 9.5 Persistence & the tracking-variable contract

Per-module `TRACK_MODE`/`TRACK_REF` live in that module's `sync.conf` —
the actual, persistent source of truth, read by both the sync engine and
`wb status`. The manifest's `branch:` field (§5.2) is a **default only**;
once a machine has its own persisted tracking state, that state is
authoritative and the manifest default is never consulted again for that
module on that machine.

The loader additionally exports a **derived, read-only**
`WORKBENCH_TRACK_<MODULE>` environment variable into the interactive shell
at startup, sourced *from* `sync.conf` (never the reverse — the background
timer can't see a live shell session's exports, so `sync.conf` has to be
the real mechanism regardless). `<MODULE>` is the module's catalog/
registration name, uppercased. This is a standardised, documented Core API
contract — published now, even though no ecosystem modules exist yet,
specifically so Wave C's modules have a settled contract to build against
rather than each inventing their own convention.

### 9.6 Developer workflow & disk duplication (expected, documented behaviour)

A developer's own working clone — wherever they manage it, `git push`ed
normally — is entirely outside anything `workbench` tracks or manages.
Pointing a module's tracking at that branch (`wb dev`/`wb track --branch`,
§10) produces a **separate**, independently-fetched snapshot for testing
"the way an end user would consume it." This means a developer actively
working on a module has two copies of the same small text files on disk
simultaneously: their own editing clone, and workbench's fetched snapshot.
This is expected and low-impact (shell config text files, not large
binaries) — but needs to be documented plainly in `module-authoring.md` and
the developer-facing docs so it isn't mistaken for a bug or for state
drift.

### 9.7 Toggles

Two independent controls, both machine-side and per-module:

- **`sync.enabled`** — whether a module auto-syncs on the timer *at all*,
  independent of what it's tracking. Defaults to the manifest's declared
  value, overridable in local state.
- **`TRACK_MODE`/`TRACK_REF`** (§9.2) — *what* it tracks when sync is
  enabled.

These are orthogonal: a module can be registered with sync disabled
entirely (frozen at whatever snapshot is currently deployed, no automatic
re-check, not even for `latest`), or registered and actively tracking any
of the four modes.

---

## 10. CLI surface & module bundles

Resolved: `workbench-core` ships a scriptable CLI, named **`wb`**, from
Wave B. `workbench` is reserved for a separate TUI repo (Wave D) that fronts
`wb` — not a competing command surface.

### `wb` subcommands

| Command | Purpose |
|---|---|
| `wb install [--bundle <n>]` | First-run convergence — prereqs, host-state generation, Ansible apply. `--bundle` expands to a sequence of `wb add` calls before applying. |
| `wb apply` | Re-run convergence without the interactive prompts (mirrors `install.sh --no-prereqs --skip-ssh` today). |
| `wb add <n> [url] [--private] [--allow-hooks]` | Hot-path registration (§8's convergence constraint applies). `url` is optional if `<n>` resolves against the known-modules catalog. Defaults new registrations to `TRACK_MODE=latest`. |
| `wb remove <n>` | Idempotent, non-destructive deregistration — never deletes deployed content the user might have touched. |
| `wb track <n> --latest \| --branch <b> \| --tag <t> \| --commit <sha>` | Sets a module's tracking mode/ref (§9.2). Mutually exclusive flags. Returning a module to production is `wb track <n> --latest`, not a separate command. |
| `wb dev [<n>]` | **Guided wrapper over `wb track`**, not a separate mechanism (confirmed). With no argument, walks through every currently-registered module (core included) prompting whether to keep it on its current tracking or switch to `--branch`/`--tag`/`--commit`; with `<n>`, jumps straight to that one module. Implicitly ensures `sync.enabled=true` for anything switched into `branch:` tracking, since dev tracking without active sync defeats the purpose. |
| `wb sync enable [<n>] \| disable [<n>]` | Toggles a module's `sync.enabled` independent of what it tracks (§9.7). No argument means the module-zero (core) toggle. |
| `wb update [<n>]` | On-demand, single-run sync-and-deploy trigger — available regardless of cadence or tracking mode. No argument syncs every registered, sync-enabled module once. |
| `wb status` | Per-module sync/apply drift, current `TRACK_MODE`/`TRACK_REF`, resolved SHA, whether a newer `latest` tag or branch commit is available, and whether the fast (5-minute) cadence is currently active. |
| `wb functions` | The generalised `get-functions` — walks every registered module's declared getters (§5). |
| `wb tools [list [--status]] \| install <n>\|all \| upgrade [<n>\|all]` | The tool-updating framework (`docs/decisions-log.md` D23, revised D43) — discovers `install-<n>` functions modules declared via `register.installers[]`. `install` always needs an explicit target (`all` lists everything and confirms first); `upgrade` only ever touches a tool whose optional `installed-<n>` predicate reports it as installed, skipping "not installed" silently and "unresponsive" (no predicate, or a bad exit code) with a report. Manual only, never on the sync timer; distinct from `wb update`, which syncs modules, not the tools their installers happen to install. |
| `wb module info <n>` \| `wb module docs <n>` | Module-published metadata, read-only (`docs/decisions-log.md` D45) — `info` combines facts core already tracks (repository, tracking state, registration) with an optional manifest `info.description`; `docs` reads `HELP.md`, falling back to `README.md`, straight from the module's synced snapshot — convention only, no manifest field. Both are inert — no functional effect on sync/deploy/the loader, so `info:` is read regardless of whether `core_api` is declared, unlike `register:`. |

### Known-modules catalog & bundles

A bundle referencing modules by name only needs somewhere to resolve
`git` → its canonical repo URL — this is new relative to the original draft,
and follows directly from keeping bundles pure sugar (principle 4: no
hardcoded profile branching in the engine). Core ships a small catalog,
host-overridable/extensible like everything else in this plan:

```yaml
# workbench-core default, overridable in host state
modules:
  git:   { url: "https://github.com/<you>/workbench-git.git",   private: false }
  gpg:   { url: "https://github.com/<you>/workbench-gpg.git",   private: false }
  ssh:   { url: "https://github.com/<you>/workbench-ssh.git",   private: false }
  shell: { url: "https://github.com/<you>/workbench-shell.git", private: false }

bundles:
  workstation: [git, gpg, ssh, shell]
  server:      [git, ssh, shell]
  minimal:     [git, ssh]
```

Default bundles mirror today's three `dotfiles` profiles for continuity, but
this is convenience only — `wb install --bundle workstation` is exactly
equivalent to four `wb add` calls, nothing more. The catalog is empty of
real URLs until Wave C's module repos exist; the *structure* ships in
Wave B so `wb add <n>`/`wb install --bundle` have somewhere to resolve
against from day one.

### Relationship to the future TUI

`workbench` (Wave D) is a front-end only. Whether it shells out to `wb`
subcommands or calls into the same shell library `wb` is built on is a
Wave D implementation choice — not needed now, and not blocking anything
before then. Worth noting as a reasonable place to pick up Go, if that's of
interest when Wave D arrives.

---

## 11. Phased rollout

| Wave | Scope |
|---|---|
| **A** | Execute the existing, already-agreed `dotfiles` freeze plan (Wave 1 T0–T5 additive, Wave 2 T6 conditional loader deprecation). Unchanged by this document — referenced for continuity only. |
| **B — core bootstrap** | Stand up `workbench-core` in a public repo from the start (D5 removes the earlier private-intermediate complication). Port loader, distro/platform/arch detection, elevation helpers, `_read_prompt`, getter pattern out of `workbench-precursor`. Add the missing prereq checks (§7), the version-taxonomy file (§6), `register:` ingestion, the multi-root loader (§3, bash-3.2-safe), the distribution mechanism and four-state tracking model (§9), and ship the `wb` CLI — `install`/`apply`/`add`/`remove`/`track`/`dev`/`sync`/`update`/`status`/`functions` — plus the known-modules-catalog structure (empty of real entries until Wave C). Dogfood on your own workstation. |
| **C — first modules** | Extract git/gpg/ssh/shell out of `workbench-precursor` into their own repos against the new contract. Populate the known-modules catalog with real URLs. Migrate `awsconfd`'s manifest to add `register:` — first real-world validation, including of the private-repo tracking path if `awsconfd` stays private. |
| **D — TUI** | Build `workbench` (front-end for `wb`) once core + a handful of real modules are stable — not before. |
| **E — go public** | N/A for `workbench-*` repos — public from the start as of D5. Independent tools that started private remain the author's choice to flip later. |

---

## 12. Decisions log

See [`docs/decisions-log.md`](decisions-log.md) for the full, numbered
decisions log. Add new entries there — never renumber or rewrite an
existing one.

---

## 13. CI

Automated lint + test pipeline, D26. `.github/workflows/ci.yml` runs
shellcheck against the shell surface (`bin/wb`, `bootstrap.sh`, `lib/`,
`tests/`, `.github/scripts/`) plus the full `tests/check-*.sh` suite across
`ubuntu-latest`/`macos-latest`, on PR-open to `main`, manual dispatch, and
`workflow_call` for `release.yml` (§14) to depend on. See the workflow
file and D26 for the mechanics and the rationale behind the shellcheck
baseline fixes that came with it.

## 14. Release automation

Automated semver/tagging/release pipeline, D27/D28. `.github/workflows/
pr-check.yml`, `release.yml`, and `release-finalize.yml`, backed by
`.github/scripts/release/`, turn Conventional-Commit-formatted merges to
`main` into version bumps, tags, and GitHub Releases without a manual cut.
`release.yml` proposes a release as a `release/v<VERSION>` PR with
auto-merge enabled (D28 — `main`'s branch ruleset requires a PR, so the
bump can't land any other way); `release-finalize.yml` tags the resulting
merge commit and publishes the GitHub Release once that PR merges. See
`docs/release-process.md` for the full mechanics — the Conventional
Commit scoping rules, the `core`-scope convention, the CHANGELOG
discipline this builds on, and what to do if a release fails its own
safety net.
