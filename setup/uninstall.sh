#!/bin/bash

# Removes everything install.sh put outside the plugin folder.
#
# `omarchy plugin remove` deletes the plugin directory and nothing else, so
# without this the wrapper, the service and the config file survive an
# uninstall and keep holding the RFCOMM socket.
#
# earctl goes too, unless --keep-earctl is passed. It is removed the way it
# was installed: through the package manager if a package owns it, otherwise
# by deleting the binary this plugin built.

set -uo pipefail

bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/earbuds"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }

keep_earctl=false
[[ ${1:-} == --keep-earctl ]] && keep_earctl=true

say "Stopping earctl.service"
systemctl --user disable --now earctl.service 2>/dev/null || true
rm -f "$unit_dir/earctl.service"
systemctl --user daemon-reload 2>/dev/null || true

say "Removing the earbuds wrapper"
rm -f "$bin_dir/earbuds"

say "Removing $conf_dir"
rm -rf "$conf_dir"

# The service is already stopped above, which matters: removing earctl out
# from under a running server would leave a dead unit behind.

# ------------------------------------------------------------------ earctl
if [[ $keep_earctl == true ]]; then
  say "Leaving earctl in place"
elif ! earctl_path=$(command -v earctl); then
  say "earctl is not installed"
else
  say "Removing earctl"
  # Ask pacman who owns it rather than guessing. A package-managed earctl
  # deleted by hand would leave pacman believing it is still installed.
  if owner=$(pacman -Qoq "$earctl_path" 2>/dev/null) && [[ -n $owner ]]; then
    note "Owned by package '$owner'; removing it through the package manager."
    if command -v yay >/dev/null; then
      yay -Rns "$owner"
    else
      sudo pacman -Rns "$owner"
    fi
  else
    note "Not owned by a package; deleting $earctl_path"
    rm -f "$earctl_path"
  fi
fi

say "Done."
