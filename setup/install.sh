#!/bin/bash

# Installs everything the plugin needs but cannot ship inside a QML folder.
#
# Runs two ways. The plugin invokes it on first load with no terminal
# attached, where it silently installs the parts that need no privileges. A
# person can also run it directly, and then it will install earctl too.
#
# Exit codes:
#   0  everything is in place
#   2  everything except earctl, which needs a terminal to install
#   3  a base dependency is missing and nothing can proceed

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/earbuds"

# Quiet when the plugin runs us, chatty when a person does.
interactive() { [[ -t 0 && -t 1 ]]; }
say() { interactive && printf '\n\033[1m%s\033[0m\n' "$*"; return 0; }
note() { interactive && printf '%s\n' "$*"; return 0; }

for dep in bluetoothctl jq; do
  command -v "$dep" >/dev/null && continue
  echo "$dep is required (install bluez-utils and jq)" >&2
  exit 3
done

# --------------------------------------------------------------- unprivileged
# Everything below this line is a file copy or a --user systemd unit, so it
# happens without asking anyone for anything.

say "Installing the earbuds wrapper into $bin_dir"
install -Dm755 "$here/earbuds" "$bin_dir/earbuds"

say "Installing and starting earctl.service"
install -Dm644 "$here/earctl.service" "$unit_dir/earctl.service"
systemctl --user daemon-reload
systemctl --user enable --now earctl.service >/dev/null 2>&1

mkdir -p "$conf_dir"
if [[ ! -r $conf_dir/address ]]; then
  # `|| true` is load-bearing: grep exits 1 when nothing matches, and with a
  # stricter shell that killed the script right here. Anyone installing
  # before pairing their earbuds, which is the normal order, got a silent
  # failure at exactly the branch meant to help them.
  addr=$(bluetoothctl devices 2>/dev/null |
    grep -iE 'nothing|[[:space:]]cmf|ear \(|buds' | head -n 1 | awk '{print $2}' || true)
  if [[ -n $addr ]]; then
    echo "$addr" >"$conf_dir/address"
    say "Pinned earbuds address $addr in $conf_dir/address"
  else
    say "No Nothing or CMF device is paired yet."
    note "Pair your earbuds and the widget will find them. To pin one by hand:"
    note "  bluetoothctl devices"
    note "  echo AA:BB:CC:DD:EE:FF > $conf_dir/address"
  fi
fi

# ----------------------------------------------------------------- privileged
# earctl is the only piece that may need a password. Without a terminal there
# is nowhere to type one, so we stop and let the panel offer a button that
# opens one.

if command -v earctl >/dev/null; then
  say "earctl already installed: $(command -v earctl)"
elif ! interactive; then
  echo "earctl is not installed and this is not a terminal" >&2
  exit 2
elif command -v yay >/dev/null; then
  say "Installing earctl from the AUR"
  yay -S --needed earctl || exit 2
elif command -v cargo >/dev/null; then
  say "Building earctl from source"
  tmp=$(mktemp -d)
  git clone --depth 1 https://github.com/DaanHessen/earctl.git "$tmp/earctl" &&
    (cd "$tmp/earctl" && cargo build --release) &&
    install -Dm755 "$tmp/earctl/target/release/earctl" "$bin_dir/earctl" || exit 2
  rm -rf "$tmp"
else
  echo "need either yay (AUR) or a rust toolchain to install earctl" >&2
  exit 2
fi

say "Done. Checking:"
interactive && "$bin_dir/earbuds" status
exit 0
