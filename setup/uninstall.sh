#!/bin/bash

# Removes what install.sh put outside the plugin folder, and only that:
# every removal is driven by the manifest, never by inference. Run BEFORE
# `omarchy plugin remove`, which deletes only the plugin directory.
#
# Without a manifest (pre-1.1.0 installs) only the wrapper and unit are
# removed, and only if their bytes match a version this plugin shipped.
# earctl goes the way it came (package or recorded binary) unless
# --keep-earctl; one we never installed is left alone.
#
# Anything left behind (edited file, non-empty dir, failed package removal)
# gives exit 6 and KEEPS the manifest: it is the proof the next run needs.
#
# Exit codes: 0 done, 4 no terminal or declined, 6 something left behind.

set -uo pipefail

here=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=setup/lib.sh
source "$here/lib.sh"

keep_earctl=false
consent=0
partial=0

interactive() { [[ -t 0 && -t 1 ]]; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }

usage() {
  printf '%s\n' \
    "usage: uninstall.sh [--yes] [--keep-earctl]" \
    "" \
    "Removes what the Nothing Buds plugin installed:" \
    "  $NB_UNIT   stopped, disabled and removed (if this plugin" \
    "                installed it)" \
    "  $NB_WRAPPER        removed (if this plugin installed it)" \
    "  files under $NB_CONF_DIR   only the ones this plugin wrote" \
    "  earctl                        the package or binary, unless it was" \
    "                                already present before the plugin" \
    "" \
    "--yes            skip the confirmation prompt" \
    "--keep-earctl    leave earctl installed"
}

for arg in "$@"; do
  case $arg in
    --yes) consent=1 ;;
    --keep-earctl) keep_earctl=true ;;
    -h|--help) usage; exit 0 ;;
    *) nb_err "unknown option: $arg"; exit 64 ;;
  esac
done

if ! interactive && (( ! consent )); then
  # --yes is consent; without it the prompt needs a terminal.
  nb_fail 4 "uninstall needs a terminal (it prompts before removing anything)"
fi

manifest_mode=false
[[ -r $NB_MANIFEST ]] && manifest_mode=true

# ------------------------------------------------------------- the plan
say "This will remove:"
if [[ $manifest_mode == true ]]; then
  while IFS=$'\t' read -r line; do
    [[ -n $line ]] || continue
    shown=${line#*$'\t'}
    case $line in
      file$'\t'*)    note "  ${shown%%$'\t'*}" ;;
      pkg$'\t'*)     note "  package $shown" ;;
      dir$'\t'*)     note "  directory $shown (only if empty)" ;;
    esac
  done <"$NB_MANIFEST"
  if $keep_earctl; then
    note "  earctl is kept (--keep-earctl)"
  fi
else
  note "  no install manifest found; only files still matching what this"
  note "  plugin ships, or has shipped in an earlier release, are removed:"
  note "  $NB_UNIT"
  note "  $NB_WRAPPER"
fi
printf '\n'
if (( ! consent )); then
  reply=""
  read -r -p "Proceed? [y/N] " reply || true
  [[ $reply == [yY]* ]] || nb_fail 4 "declined"
fi

# ------------------------------------------------- the service, first of all
# Stop the service before touching anything it serves.
unit_owned=false
unit_sha=""
if [[ $manifest_mode == true ]]; then
  if nb_manifest_has file "$NB_UNIT"; then
    unit_owned=true
    unit_sha=$(nb_manifest_sha "$NB_UNIT")
  fi
else
  # Today's unit is a rendered template, so only a pre-manifest release can match verbatim.
  installed_unit=$(nb_sha_file "$NB_UNIT" 2>/dev/null) || installed_unit=""
  if [[ -n $installed_unit ]] && nb_is_shipped_sha "$installed_unit"; then
    unit_owned=true
    # The helper re-verifies the hash independently.
    unit_sha=$installed_unit
  fi
fi

if [[ $unit_owned == true ]]; then
  say "Stopping and removing earctl.service"
  $NB_SYSTEMCTL --user disable --now earctl.service >/dev/null 2>&1 || true
  nb_remove_owned_file "$NB_UNIT" "$unit_sha"
  case $? in
    1|2) note "  left in place (see note above)"; partial=1 ;;
    6)   partial=1 ;;
  esac
  $NB_SYSTEMCTL --user daemon-reload >/dev/null 2>&1 || true
else
  note "earctl.service was not installed by this plugin; leaving it running."
fi

# ------------------------------------------------------------------ wrapper
wrapper_sha=""
if [[ $manifest_mode == true ]]; then
  wrapper_sha=$(nb_manifest_sha "$NB_WRAPPER")
else
  shipped_wrapper=$(nb_sha_file "$here/earbuds") || shipped_wrapper=""
  installed_wrapper=$(nb_sha_file "$NB_WRAPPER" 2>/dev/null) || installed_wrapper=""
  if [[ -n $installed_wrapper ]] &&
     { [[ $installed_wrapper == "$shipped_wrapper" ]] || nb_is_shipped_sha "$installed_wrapper"; }; then
    wrapper_sha=$installed_wrapper
  fi
fi
say "Removing the earbuds wrapper"
if [[ -n $wrapper_sha ]] && nb_remove_owned_file "$NB_WRAPPER" "$wrapper_sha"; then
  :
else
  note "  left in place: not provably installed by this plugin."
  partial=1
fi

# --------------------------------------------------------------- config files
# Collect first so the loop runs in this shell and can set the exit code.
if [[ $manifest_mode == true ]]; then
  conf_files=()
  while IFS= read -r p; do
    [[ -e $p || -L $p ]] || continue
    case $p in
      "$NB_CONF_DIR"/*) conf_files+=("$p") ;;
    esac
  done < <(nb_manifest_paths file)

  for p in "${conf_files[@]}"; do
    say "Removing $p"
    nb_remove_owned_file "$p" "$(nb_manifest_sha "$p")"
    case $? in
      1|2|6) partial=1 ;;
    esac
  done

  if nb_manifest_has dir "$NB_CONF_DIR"; then
    say "Removing $NB_CONF_DIR"
    if nb_remove_owned_dir "$NB_CONF_DIR"; then
      :
    else
      note "  left in place (see note above)."
      partial=1
    fi
  elif nb_manifest_has pre "$NB_CONF_DIR"; then
    note "Leaving $NB_CONF_DIR: it existed before this plugin."
  fi
else
  note "Leaving $NB_CONF_DIR untouched: no manifest, so nothing can be proven."
fi

# ------------------------------------------------------------------- earctl
if [[ $keep_earctl == true ]]; then
  say "Leaving earctl in place (--keep-earctl)"
elif [[ $manifest_mode == true ]]; then
  if nb_manifest_has pkg earctl; then
    say "Removing the earctl package (this may ask for your password)"
    if [[ -x $NB_YAY ]]; then
      $NB_YAY -Rns earctl
    else
      $NB_SUDO "$NB_PACMAN" -Rns earctl
    fi
    if [[ $? == 0 ]]; then
      nb_manifest_del pkg earctl
    else
      note "  package removal failed; the record is kept so a retry can find it."
      partial=1
    fi
  elif nb_manifest_has file "$NB_BIN_DIR/earctl"; then
    say "Removing the earctl binary this plugin built"
    nb_remove_owned_file "$NB_BIN_DIR/earctl" "$(nb_manifest_sha "$NB_BIN_DIR/earctl")"
    case $? in
      1|2|6) partial=1 ;;
    esac
  else
    note "Leaving earctl: this plugin did not install it."
  fi
else
  note "Leaving earctl: this plugin did not install it."
fi

# ------------------------------------------------------- state and manifest
# Our own bookkeeping; goes only on a clean uninstall, since on a partial
# one the manifest is the ownership proof. Deepest-first, empty dirs only.
if [[ $manifest_mode == true ]]; then
  say "Removing plugin state in $NB_STATE_DIR"
  nb_remove_owned_file "$NB_EARCTL_BIN_FILE" "$(nb_manifest_sha "$NB_EARCTL_BIN_FILE")"
  case $? in
    1|2|6) partial=1 ;;
  esac

  owned_dirs=()
  while IFS= read -r d; do
    owned_dirs+=("$d")
  done < <(nb_manifest_paths dir)

  if (( ! partial )); then
    $NB_RM -f -- "$NB_MANIFEST" 2>/dev/null || true
  fi
  $NB_RM -f -- "$NB_BACKUP_DIR"/* 2>/dev/null || true
  $NB_RMDIR -- "$NB_BACKUP_DIR" 2>/dev/null || true

  for (( i = ${#owned_dirs[@]} - 1; i >= 0; i-- )); do
    [[ -d ${owned_dirs[$i]} ]] || continue
    $NB_RMDIR -- "${owned_dirs[$i]}" 2>/dev/null ||
      { note "  leaving ${owned_dirs[$i]} behind: not empty"; partial=1; }
  done

  if (( ! partial )); then
    $NB_RMDIR -- "$NB_STATE_DIR" 2>/dev/null || true
  fi
fi

if (( partial )); then
  nb_fail 6 "some objects were left behind; see the notes above"
fi
say "Done."
exit 0
