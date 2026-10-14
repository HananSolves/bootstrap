# Bootstrap

Bootstrap script for a fresh Fedora (KDE) install. Clones and stows
[dotfiles](https://github.com/HananSolves/dotfiles), adds third-party repos, then installs packages via dnf, Flatpak
and Homebrew — with a TUI to pick what gets installed, a live progress dashboard, detailed logs, automatic retries and
resume after interruptions.

## Usage

```bash
git clone https://github.com/HananSolves/bootstrap.git ~/bootstrap && ~/bootstrap/bootstrap.sh
```

> **Note:** `curl | bash` won't work here — the script needs `lib/` and the package lists sitting next to it on disk.

What happens:

1. **Preflight** — asks for sudo once (kept alive for the whole run), waits for internet if it's down, and installs
   the few tools the script itself needs (`newt` for the dialogs, `util-linux-script` for live progress bars, `stow`).
2. **Choose** — a checklist of what to set up (system upgrade, dotfiles, third-party apps, dnf, Flatpak, Homebrew).
   For each package source you pick **Install all** or **Choose individually**, which lists every package to toggle.
3. **Run** — a dashboard with a pinned header (phase, overall progress bar, done/failed/skipped counts, current item)
   while each tool's own output — including its download progress bars — scrolls underneath.
4. **Summary** — what installed, what failed and why, and where the logs are.

### Options

| Option             | Effect                                                                     |
|--------------------|----------------------------------------------------------------------------|
| `-y`, `--yes`      | Don't ask what to install — install everything listed (or resume)          |
| `--only LIST`      | Only these phases: `upgrade,dotfiles,thirdparty,dnf,flatpak,brew`          |
| `--resume`         | Resume the previous unfinished run without asking                          |
| `--fresh`          | Ignore the previous run and choose packages again                          |
| `--no-tui`         | Plain output and y/n prompts (one per package when choosing individually)  |
| `--retries N`      | Attempts per item before giving up (default 3)                             |
| `--net-timeout S`  | How long to wait for a lost connection before asking what to do (1800)     |

`./thirdparty-repos.sh` is a shortcut for `./bootstrap.sh --only thirdparty`.

## Reliability

- **Every item is independent.** Each package is installed, then verified (`rpm -q`, `flatpak info`, `brew list`); one
  bad name or dead repo only fails that item. Third-party repos are added only for apps you selected and are marked
  `skip_if_unavailable`.
- **Retries with backoff.** Failed items are retried (10s, 20s…). Failures that can't succeed on retry — an unknown
  package name, a dependency conflict — are detected and not retried.
- **Network drops.** Before each item the script checks connectivity; if offline it pauses with a live
  "waiting for connection" status and continues when the link is back. dnf is configured to ride out stalls
  (`timeout=120`, `minrate=100`), and RPMs it already downloaded stay cached for the retry. Direct downloads (Proton
  Authenticator RPM, Homebrew installer, repo files) resume from the last byte (`curl --continue-at -`), even across
  runs; Homebrew resumes partial bottle downloads itself.
- **Resume.** Progress is saved after every item in `~/.local/state/bootstrap/`. If a run is interrupted — Ctrl-C,
  closed terminal, reboot — or finishes with failures, the next run offers to resume, skipping everything that already
  succeeded.
- **Ctrl-C** during an install asks: retry it, skip it, or quit (and resume later).
- **Dotfile conflicts.** Files that would block `stow` (e.g. Fedora's default `~/.bashrc`) are moved to
  `~/.dotfiles-backup/<timestamp>/` instead of aborting.
- **No sleep, no double runs.** The machine is kept awake during the run, and a lock prevents two runs at once.

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

- `packages-dnf.txt` — one package per line; `@group` for dnf groups; `#` comments allowed
- `packages-flatpak.txt` — Flathub app IDs
- `Brewfile` — `brew "name"` and `tap "user/repo"` lines
- Third-party apps — defined in `lib/thirdparty.sh` (add an id, a description and a `tp_<id>` function)

`get-installed-packages.sh` regenerates the first three from an already-configured machine.
