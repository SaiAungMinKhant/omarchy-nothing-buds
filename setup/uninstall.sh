#!/bin/bash

# Removes everything install.sh put outside the plugin folder.
#
# `omarchy plugin remove` deletes the plugin directory and nothing else, so
# without this the wrapper, the service and the config file survive an
# uninstall and keep holding the RFCOMM socket.
#
# earctl itself is left alone: you may have installed it for other tools, and
# removing an AUR package on someone's behalf is not this script's business.

set -uo pipefail

bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/earbuds"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Stopping earctl.service"
systemctl --user disable --now earctl.service 2>/dev/null || true
rm -f "$unit_dir/earctl.service"
systemctl --user daemon-reload 2>/dev/null || true

say "Removing the earbuds wrapper"
rm -f "$bin_dir/earbuds"

say "Removing $conf_dir"
rm -rf "$conf_dir"

say "Done. earctl was left in place; remove it yourself if nothing else uses it:"
echo "  yay -Rns earctl        # if installed from the AUR"
echo "  rm -f $bin_dir/earctl  # if built from source"
