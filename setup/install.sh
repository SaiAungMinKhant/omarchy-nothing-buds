#!/bin/bash

# Installs what the plugin needs outside its QML folder. Nothing happens
# without consent: the panel passes --yes (the click), a terminal run gets a
# y/N prompt. Every created object is recorded in the manifest and rolled
# back on failure, except a package yay already installed (undoing it would
# need the same password). earctl is resolved first because it alone may
# need a terminal. --check reports whether everything is installed and
# current (wrapper byte-identical to the shipped one) and changes nothing.
#
# Exit codes:
#   0  done
#   1  --check only: missing or out of date
#   2  earctl missing, needs a terminal; nothing else changed
#   3  bluetoothctl or jq missing
#   4  consent not given
#   5  pre-existing object refused (see --replace-existing)
#   6  operational failure; rolled back

set -uo pipefail

here=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=setup/lib.sh
source "$here/lib.sh"

NB_ROLLBACK_ENABLED=1
NB_REPLACE_EXISTING=0
consent=0
check_only=0
build_tmp=""

# Clean the build dir on any exit, including signals.
nb_cleanup_build() { [[ -n $build_tmp ]] && $NB_RM -rf -- "$build_tmp" || true; }
trap 'nb_cleanup_build' EXIT
trap 'nb_cleanup_build; exit 130' INT
trap 'nb_cleanup_build; exit 143' TERM

# Full commit SHA (earctl v0.1.2), never a movable tag.
earctl_commit=81b24e15ffa12d04ddad957e8ac0da557e37b38d

interactive() { [[ -t 0 && -t 1 ]]; }
say()  { interactive && printf '\n\033[1m%s\033[0m\n' "$*"; return 0; }
note() { interactive && printf '%s\n' "$*"; return 0; }

usage() {
  printf '%s\n' \
    "usage: install.sh [--yes] [--replace-existing] [--check]" \
    "" \
    "Installs the Nothing Buds plugin's pieces outside its QML folder:" \
    "  $NB_WRAPPER        the earbuds helper command" \
    "  $NB_UNIT           systemd --user service (earctl RFCOMM server)" \
    "  $NB_CONF_DIR/            config: pinned earbuds address, RFCOMM channel" \
    "  earctl                   Nothing RFCOMM tool, from the AUR or source" \
    "" \
    "--yes                skip the confirmation prompt (used by the panel," \
    "                    where the click on \"Set up\" is the confirmation)" \
    "--replace-existing   also replace pre-existing files at the paths above" \
    "                    that this plugin cannot prove it owns; the previous" \
    "                    copy is kept in $NB_BACKUP_DIR first" \
    "--check              exit 0 if everything above is installed and current," \
    "                    else 1; changes nothing and asks nothing"
}

# Present and current, checked the way the wrapper checks itself: regular files, no symlinks.
check_installed() {
  local want got
  [[ -x $NB_BT && -x $NB_JQ ]] || return 1
  [[ -e $NB_WRAPPER && ! -L $NB_WRAPPER && -f $NB_WRAPPER && -x $NB_WRAPPER ]] || return 1
  want=$(nb_sha_file "$here/earbuds") || return 1
  got=$(nb_sha_file "$NB_WRAPPER") || return 1
  [[ $want == "$got" ]] || return 1
  [[ -e $NB_UNIT && ! -L $NB_UNIT && -f $NB_UNIT ]] || return 1
  [[ -f $NB_EARCTL_FALLBACK && -x $NB_EARCTL_FALLBACK ]] ||
    [[ -e $NB_BIN_DIR/earctl && ! -L $NB_BIN_DIR/earctl && -f $NB_BIN_DIR/earctl && -x $NB_BIN_DIR/earctl ]] ||
    return 1
  return 0
}

for arg in "$@"; do
  case $arg in
    --yes) consent=1 ;;
    --replace-existing) NB_REPLACE_EXISTING=1 ;;
    --check) check_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) nb_err "unknown option: $arg"; exit 64 ;;
  esac
done

if (( check_only )); then
  check_installed && exit 0
  exit 1
fi

if (( ! consent )); then
  if ! interactive; then
    nb_fail 4 "consent required: run from a terminal or pass --yes"
  fi
  usage
  printf '\n'
  reply=""
  read -r -p "Proceed? [y/N] " reply || true
  [[ $reply == [yY]* ]] || nb_fail 4 "declined"
fi

for dep in "$NB_BT" "$NB_JQ"; do
  [[ -x $dep ]] || nb_fail 3 "$dep is required (install bluez-utils and jq)"
done

# The manifest lives here; created fresh on a new install.
nb_ensure_dir_chain "$NB_STATE_DIR" || nb_fail $? "could not prepare $NB_STATE_DIR"

# ----------------------------------------------------------------- earctl
# Resolved first. /usr/bin is trusted by ownership; a user-location binary must be a regular file.
NB_EARCTL_PATH=""
NB_EARCTL_OURS=""

if [[ -f $NB_EARCTL_FALLBACK && -x $NB_EARCTL_FALLBACK ]]; then
  NB_EARCTL_PATH=$NB_EARCTL_FALLBACK
  if nb_manifest_has pkg earctl; then
    NB_EARCTL_OURS=pkg
  else
    NB_EARCTL_OURS=pre
    nb_manifest_set pre "$NB_EARCTL_FALLBACK" || nb_fail 6 "could not record manifest"
  fi
elif [[ -e $NB_BIN_DIR/earctl && ! -L $NB_BIN_DIR/earctl && -f $NB_BIN_DIR/earctl && -x $NB_BIN_DIR/earctl ]]; then
  NB_EARCTL_PATH=$NB_BIN_DIR/earctl
  if nb_manifest_has file "$NB_BIN_DIR/earctl"; then
    NB_EARCTL_OURS=file
  else
    NB_EARCTL_OURS=pre
    nb_manifest_set pre "$NB_BIN_DIR/earctl" || nb_fail 6 "could not record manifest"
  fi
fi

if [[ -z $NB_EARCTL_PATH ]]; then
  if ! interactive; then
    # May need a password, and there is no terminal to type it in.
    nb_fail 2 "earctl is not installed and this is not a terminal"
  fi
  if [[ -x $NB_YAY ]]; then
    say "Installing earctl from the AUR"
    $NB_YAY -S --needed earctl || nb_fail 2 "earctl install failed; re-run when fixed"
    [[ -f $NB_EARCTL_FALLBACK && -x $NB_EARCTL_FALLBACK ]] ||
      nb_fail 2 "yay finished but $NB_EARCTL_FALLBACK is missing"
    nb_manifest_set pkg earctl || nb_fail 6 "could not record manifest"
    NB_EARCTL_PATH=$NB_EARCTL_FALLBACK
    NB_EARCTL_OURS=pkg
  elif earctl_cargo=$(nb_cargo); then
    say "Building earctl $earctl_commit from source"
    build_tmp=$($NB_MKTEMP -d) || nb_fail 6 "mktemp failed"

    # Fetch the pinned commit, check it out detached, verify HEAD before building.
    $NB_GIT init -q "$build_tmp/earctl" &&
      $NB_GIT -C "$build_tmp/earctl" remote add origin https://github.com/DaanHessen/earctl.git &&
      $NB_GIT -C "$build_tmp/earctl" fetch -q --depth 1 origin "$earctl_commit" &&
      $NB_GIT -C "$build_tmp/earctl" checkout -q --detach "$earctl_commit" ||
      nb_fail 2 "could not fetch earctl $earctl_commit"

    got=$($NB_GIT -C "$build_tmp/earctl" rev-parse HEAD)
    [[ $got == "$earctl_commit" ]] ||
      nb_fail 2 "earctl checkout is $got, expected $earctl_commit"

    (cd "$build_tmp/earctl" && "$earctl_cargo" build --release) ||
      nb_fail 2 "earctl build failed"

    # Same ownership checks as everywhere else: a foreign ~/.local/bin/earctl is refused.
    nb_install_file "$build_tmp/earctl/target/release/earctl" "$NB_BIN_DIR/earctl" 755
    NB_EARCTL_PATH=$NB_BIN_DIR/earctl
    NB_EARCTL_OURS=file
  else
    nb_fail 2 "need either yay (AUR) or a rust toolchain to install earctl"
  fi
fi

[[ -f $NB_EARCTL_PATH && -x $NB_EARCTL_PATH ]] ||
  nb_fail 6 "resolved earctl at $NB_EARCTL_PATH but it is not executable"

# Record which earctl the wrapper calls, so it never guesses.
nb_write_owned "$NB_EARCTL_BIN_FILE" 644 "$NB_EARCTL_PATH"

# ----------------------------------------------------------------- wrapper
say "Installing the earbuds wrapper into $NB_BIN_DIR"
nb_install_file "$here/earbuds" "$NB_WRAPPER" 755

# ------------------------------------------------------------------ config
if [[ -L $NB_CONF_DIR ]]; then
  nb_fail 5 "refusing to operate through symlink $NB_CONF_DIR"
fi
if [[ -d $NB_CONF_DIR ]]; then
  nb_manifest_set pre "$NB_CONF_DIR" || nb_fail 6 "could not record manifest"
else
  nb_ensure_dir_chain "$NB_CONF_DIR" || nb_fail $? "could not prepare $NB_CONF_DIR"
fi

# A pre-existing address file always wins.
if ! [[ -r $NB_CONF_DIR/address ]]; then
  # `|| true`: grep exits 1 on no match.
  addr=$($NB_TIMEOUT 10 "$NB_BT" devices 2>/dev/null |
    $NB_HEAD -c 8192 |
    $NB_GREP -iE 'nothing|[[:space:]]cmf|ear \(|buds' |
    $NB_HEAD -n 1 |
    $NB_AWK '{print $2}' || true)
  nb_valid_addr "$addr" || addr=""
  if [[ -n $addr ]]; then
    nb_write_if_absent "$NB_CONF_DIR/address" 644 "$addr"
    case $? in
      0) say "Pinned earbuds address $addr in $NB_CONF_DIR/address" ;;
      2) note "A symlink already exists at $NB_CONF_DIR/address; leaving it alone" ;;
    esac
  else
    say "No Nothing or CMF device is paired yet."
    note "Pair your earbuds and the widget will find them. To pin one by hand:"
    note "  bluetoothctl devices"
    note "  echo AA:BB:CC:DD:EE:FF > $NB_CONF_DIR/address"
  fi
fi

# -------------------------------------------------------------------- unit
say "Installing and starting earctl.service"
# ExecStart is rendered from the resolved earctl so the service and the
# wrapper run the same binary; the render is verified.
unit_body=$($NB_SED "s|^ExecStart=.*|ExecStart=$NB_EARCTL_PATH server --addr 127.0.0.1:8787|" "$here/earctl.service") ||
  nb_fail 6 "could not read earctl.service"
case $unit_body in
  *"ExecStart=$NB_EARCTL_PATH server --addr 127.0.0.1:8787"*) ;;
  *) nb_fail 6 "could not render ExecStart for $NB_EARCTL_PATH" ;;
esac
nb_write_owned "$NB_UNIT" 644 "$unit_body"
$NB_SYSTEMCTL --user daemon-reload || nb_fail 6 "systemctl --user daemon-reload failed"
if ! $NB_SYSTEMCTL --user enable --now earctl.service >/dev/null; then
  # Rollback removes files, not systemd state, so undo that here.
  $NB_SYSTEMCTL --user disable earctl.service >/dev/null 2>&1 || true
  $NB_SYSTEMCTL --user daemon-reload >/dev/null 2>&1 || true
  nb_fail 6 "could not enable earctl.service"
fi

say "Done."
if interactive; then
  note "Checking:"
  "$NB_WRAPPER" status
fi
exit 0
