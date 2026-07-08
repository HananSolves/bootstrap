# Bootstrap

Bootstrap script for a fresh Fedora (KDE) install. Installs git+stow,
clones and stows [dotfiles](https://github.com/HananSolves/dotfiles),
then reinstalls packages via dnf, Flatpak, and Homebrew.

## Usage

```bash
git clone git@github.com:HananSolves/bootstrap.git ~/bootstrap
cd ~/bootstrap && ./bootstrap.sh
```

Or, once pushed:

```bash
curl -fsSL https://raw.githubusercontent.com/HananSolves/bootstrap/main/bootstrap.sh | bash
```
