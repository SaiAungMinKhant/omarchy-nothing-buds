#!/bin/bash

# Installs everything the Earbuds plugin needs but cannot ship itself: the
# earctl binary, the `earbuds` wrapper, and the systemd user service that
# holds the RFCOMM session open.
#
# Omarchy plugins are QML only -- there is no dependency declaration or
# post-install hook in the plugin system -- so this is run by hand once.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/earbuds"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v bluetoothctl >/dev/null || { echo "bluez-utils is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# ---------------------------------------------------------------- earctl
if command -v earctl >/dev/null; then
  say "earctl already installed: $(command -v earctl)"
else
  say "Installing earctl"
  if command -v yay >/dev/null; then
    yay -S --needed earctl
  elif command -v cargo >/dev/null; then
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/DaanHessen/earctl.git "$tmp/earctl"
    (cd "$tmp/earctl" && cargo build --release)
    install -Dm755 "$tmp/earctl/target/release/earctl" "$bin_dir/earctl"
    rm -rf "$tmp"
  else
    echo "need either yay (AUR) or a rust toolchain to install earctl" >&2
    exit 1
  fi
fi

# --------------------------------------------------------------- wrapper
say "Installing the earbuds wrapper into $bin_dir"
install -Dm755 "$here/earbuds" "$bin_dir/earbuds"

# --------------------------------------------------------------- service
say "Installing and starting earctl.service"
install -Dm644 "$here/earctl.service" "$unit_dir/earctl.service"
systemctl --user daemon-reload
systemctl --user enable --now earctl.service

# ------------------------------------------------------------------ pair
mkdir -p "$conf_dir"
if [[ ! -r $conf_dir/address ]]; then
  addr=$(bluetoothctl devices 2>/dev/null |
    grep -iE 'nothing|[[:space:]]cmf|ear \(|buds' | head -n 1 | awk '{print $2}')
  if [[ -n $addr ]]; then
    echo "$addr" >"$conf_dir/address"
    say "Pinned earbuds address $addr in $conf_dir/address"
  else
    say "No Nothing/CMF device found. Pair your earbuds, then write their MAC to $conf_dir/address"
  fi
fi

say "Done. Checking:"
"$bin_dir/earbuds" status
