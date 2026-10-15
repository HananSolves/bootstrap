# Bootstrap

[![CI](https://github.com/HananSolves/bootstrap/actions/workflows/ci.yml/badge.svg)](https://github.com/HananSolves/bootstrap/actions/workflows/ci.yml)

Bootstrap script for a fresh Fedora (KDE) install. Removes preinstalled packages you don't want, clones and stows
[dotfiles](https://github.com/HananSolves/dotfiles), adds third-party repos, then installs packages via dnf, Flatpak
and Homebrew — with a minimal TUI to pick what to do (including extra packages found by searching), a live progress
dashboard, detailed logs, automatic retries, resume after interruptions and a desktop notification when it's done.

## Usage

```bash
git clone https://github.com/HananSolves/bootstrap.git ~/bootstrap && ~/bootstrap/bootstrap.sh
```

> **Note:** `curl | bash` won't work here — the script needs `lib/` and the package lists sitting next to it on disk.

What happens:

1. **Preflight** — asks for sudo once (kept alive for the whole run), waits for internet if it's down, and installs
   the few tools the script itself needs ([`gum`](https://github.com/charmbracelet/gum) for the menus — it's in
   Fedora's repos — `util-linux-script` for live progress bars, `stow`, `gnupg2`).
2. **Choose** — it checks what's already installed, then shows one menu with a line per phase and package source and
   its current selection:

   ```
   ◆ Fedora Bootstrap

   › ● Remove packages    3 to remove · 1 already gone
     ○ System upgrade     off
     ● Dotfiles           clone + stow
     ● DNF packages       4 to install · 17 installed
     ● Flatpak apps       2 to install · 12 installed
     → Start              9 to do · 30 already done
   ```

   Open any line, change it, come back, open another — in any order. Nothing changes on the system until **Start**.
   Each source offers **Pick packages** (a checklist marking what's installed), **Search** (Fedora's repos, Flathub,
   Homebrew — or, for removals, your installed packages), **Select all / only the ones not installed / none**.
   Packages added by searching can be saved to the lists for future runs.
3. **Run** — a small pinned header (phase, progress bar, counts, current item) while each tool's own output scrolls
   underneath.
4. **Summary** — what was installed or removed, what was already done, what failed and why, where the logs are — and
   a desktop notification, so you can walk away during a long run.

**Keys:** arrows move, Enter opens/confirms, Space or x toggles in lists, Ctrl-A selects all, Esc goes back a screen
(on the main menu: asks whether to quit), Ctrl-C during the run pauses it (retry / skip / quit and resume later).

### Options

| Option             | Effect                                                                     |
|--------------------|----------------------------------------------------------------------------|
| `-y`, `--yes`      | Don't ask — do everything listed (or resume an unfinished run)             |
| `--only LIST`      | Only these phases: `remove,upgrade,dotfiles,thirdparty,dnf,flatpak,brew`   |
| `--resume`         | Resume the previous unfinished run without asking                          |
| `--fresh`          | Ignore the previous run and choose packages again                          |
| `--no-tui`         | Plain output, numbered menus and y/n prompts instead of the gum TUI        |
| `--downloads N`    | Files dnf and Homebrew download at once, 1–20 (default: dnf 10, brew auto) |
| `--no-notify`      | No desktop notification at the end                                         |
| `--retries N`      | Attempts per item before giving up (default 3)                             |
| `--net-timeout S`  | How long to wait for a lost connection before asking what to do (1800)     |

`./thirdparty-repos.sh` is a shortcut for `./bootstrap.sh --only thirdparty`.

## Speed

- **One transaction per source.** Before going item by item, every missing package of a source is installed in a
  single `dnf install` / `flatpak install` / `brew install`: dependencies are resolved once and downloads overlap.
  Each item is then verified on its own, and anything the batch didn't manage is retried one at a time — so one bad
  name never blocks the rest (`dnf --skip-unavailable`; an unknown Flatpak ID is dropped and the batch retried).
- **Parallel downloads.** dnf fetches 10 files at once (its default is 3) and Homebrew sizes its pool from the CPU
  count. On a slow or metered link, `--downloads 2` is gentler. Installs themselves can't run in parallel: dnf,
  Flatpak and Homebrew each lock their own database while installing.

## Reliability

- **Every item is independent.** Each package is installed, then verified (`rpm -q`, `flatpak info`, `brew list`); one
  bad name or dead repo only fails that item. Third-party repos are added only for apps you selected and are marked
  `skip_if_unavailable`.
- **Retries with backoff.** Failed items are retried (10s, 20s…). Failures that can't succeed on retry — an unknown
  package name, a dependency conflict — are detected and not retried. A broken metadata file from a mirror is
  cleared from dnf's cache before the retry.
- **Network drops.** Before each item the script checks connectivity; if offline it pauses with a live
  "waiting for connection" status and continues when the link is back. dnf is configured to ride out stalls
  (`timeout=120`, `minrate=100`), and RPMs it already downloaded stay cached for the retry. Direct downloads resume
  from the last byte (`curl --continue-at -`), even across runs; Homebrew resumes partial bottle downloads itself.
- **Resume.** Progress is saved after every item in `~/.local/state/bootstrap/`. If a run is interrupted — Ctrl-C,
  closed terminal, reboot — or finishes with failures, the next run offers to resume, skipping everything that already
  succeeded.
- **Dotfile conflicts.** Files that would block `stow` (e.g. Fedora's default `~/.bashrc`) are moved to
  `~/.dotfiles-backup/<timestamp>/` instead of aborting.
- **No sleep, no double runs.** The machine is kept awake during the run, and a lock prevents two runs at once.

## Security

Every third-party package is signature-checked before it's installed:

| App                  | Package check                     | Repo metadata check |
|----------------------|-----------------------------------|---------------------|
| VS Code              | Microsoft key                     | Microsoft key       |
| Cursor               | Anysphere key                     | Anysphere key       |
| Antigravity          | Google Linux packages key         | — (see below)       |
| Mullvad Browser      | Mullvad key                       | Mullvad key         |
| WezTerm (Copr)       | Copr project key                  | — (not signed)      |
| Proton Authenticator | SHA-512 from Proton's update manifest (Proton doesn't sign this RPM) | — |

The vendors' public keys are **committed in [`keys/`](keys/)** (fingerprints in `keys/sources.tsv`) and installed
from there to `/etc/pki/rpm-gpg/`; every `.repo` file is written by the script and points at that local copy.
Nothing trust-related is downloaded or parsed at install time, so a tampered download can't add a key or turn
checking off. A weekly CI job checks that each vendor still publishes the same key — if one rotates, verify the new
key from the vendor's documentation and update `keys/`.

Antigravity's repo metadata is signed, but dnf5 rejects that signature, so only its packages are checked.

## Removing packages

`packages-remove.txt` lists packages to remove — run first, before anything is installed:

```
kmahjongg              # a dnf package
@kde-education         # a dnf group
flatpak:org.kde.kpat   # a Flatpak app (per-user or system-wide)
```

Removal is careful: dnf's own preview runs first, and if other installed packages depend on the one being removed,
it's left alone (and reported) — unless those dependents are on the list too, in which case they go together. dnf
also refuses to touch protected packages such as the kernel or `plasma-desktop`. The **Remove packages** screen can
search your installed packages to find exact names.

## Logs

Each run writes to `~/.local/state/bootstrap/logs/<timestamp>/` (`latest` points at the newest; the last 20 are kept):

- `bootstrap.log` — timestamped record of every decision, command, its cleaned output, exit code and duration
- `steps/NNN-<source>-<name>.log` — raw terminal output of each attempt at each item
- `report.tsv` — one row per item: source, name, status, seconds, detail
- `summary.txt` — the end-of-run summary

```bash
less -R ~/.local/state/bootstrap/logs/latest/bootstrap.log
```

## Package lists

- `packages-remove.txt` — packages to remove (see above)
- `packages-dnf.txt` — one package per line; `@group` for dnf groups; `#` comments allowed
- `packages-flatpak.txt` — Flathub app IDs
- `Brewfile` — `brew "name"` and `tap "user/repo"` lines
- Third-party apps — defined in `lib/thirdparty.sh` (add an id, a description and a `tp_<id>` function)

`get-installed-packages.sh` regenerates the dnf, Flatpak and Homebrew lists from an already-configured machine.
Packages added through the search screens are appended to these files if you choose to save them.

## CI

`.github/workflows/ci.yml` runs on every push, every pull request and weekly:

- **shellcheck** over every script
- **package lists** — checks that every entry still exists: dnf names and groups in Fedora's repos, Flatpak IDs on
  Flathub, formulae in Homebrew's index. A renamed or dropped package shows up as an annotation on its line. The
  weekly run catches packages that disappear upstream while the repo doesn't change.
- **vendor keys** — checks that each vendor still publishes the key committed in `keys/`
- **smoke test** — runs `bootstrap.sh` for real in a Fedora container (install, remove, then a second run that must
  change nothing)
