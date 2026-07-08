# Bootstrap

Bootstrap script for a fresh Fedora (KDE) install. Installs git+stow,
clones and stows [dotfiles](https://github.com/HananSolves/dotfiles),
then reinstalls packages via dnf, Flatpak, and Homebrew.

## Usage

```bash
git clone git@github.com:HananSolves/bootstrap.git ~/bootstrap
cd ~/bootstrap && ./bootstrap.sh
```

Or, as a one-liner on a fresh install (clones the repo, then runs the script from disk so it can find the package
list files sitting alongside it):

```bash
git clone https://github.com/HananSolves/bootstrap.git ~/bootstrap && ~/bootstrap/bootstrap.sh
```

> **Note:** `curl | bash` won't work here — it only fetches `bootstrap.sh` itself, not the
> `packages-dnf.txt` / `packages-flatpak.txt` / `Brewfile` files it depends on, and the script needs to know its
> own location on disk to find them.
