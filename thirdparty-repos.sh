#!/usr/bin/env bash
# thirdparty-repos.sh
# Installs only the third-party apps (VS Code, Cursor, Antigravity, Mullvad
# Browser, WezTerm, Proton Authenticator). The app definitions live in
# lib/thirdparty.sh; this runs bootstrap.sh limited to that phase, so you get
# the same selection dialog, live progress, retries, logs and resume.
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bootstrap.sh" --only thirdparty "$@"
