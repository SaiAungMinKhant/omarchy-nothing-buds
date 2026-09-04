#!/bin/bash

# Shared install primitives, sourced by install.sh, uninstall.sh and test.sh.
#
# Rules: external commands by absolute path only; user-writable locations must
# resolve to regular files and are never written through a symlink; only
# objects we can prove we own (manifest record, or bytes we ship or shipped)
# are replaced, else exit 5 unless --replace-existing; writes are temp file +
# rename; everything created is recorded so uninstall removes only that.
#
# Install-side mutators call nb_fail (exit + rollback); uninstall-side helpers
# return codes, since a partial uninstall is reported, not rolled back.
#
# Manifest records, TAB-separated:
#   file<TAB>path<TAB>sha256   dir<TAB>path   pkg<TAB>name   pre<TAB>path

# ---------------------------------------------------------------------- paths

NB_ID=io.github.saiaungminkhant.nothing-buds
NB_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/$NB_ID
NB_MANIFEST=$NB_STATE_DIR/manifest
NB_BACKUP_DIR=$NB_STATE_DIR/backup
NB_BIN_DIR=$HOME/.local/bin
NB_UNIT_DIR=$HOME/.config/systemd/user
NB_CONF_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/earbuds
NB_WRAPPER=$NB_BIN_DIR/earbuds
NB_UNIT=$NB_UNIT_DIR/earctl.service
NB_EARCTL_BIN_FILE=$NB_STATE_DIR/earctl-bin

# Absolute paths. setup/earbuds carries its own copy of the subset it needs;
# test.sh rewrites both.

NB_BT=/usr/bin/bluetoothctl
NB_JQ=/usr/bin/jq
NB_SYSTEMCTL=/usr/bin/systemctl
NB_PACMAN=/usr/bin/pacman
NB_SUDO=/usr/bin/sudo
NB_YAY=/usr/bin/yay
NB_GIT=/usr/bin/git
NB_TIMEOUT=/usr/bin/timeout
NB_SHA=/usr/bin/sha256sum
NB_TEST=/usr/bin/test
NB_READLINK=/usr/bin/readlink
NB_EARCTL_FALLBACK=/usr/bin/earctl

NB_BASENAME=/usr/bin/basename
NB_CHMOD=/usr/bin/chmod
NB_CP=/usr/bin/cp
NB_DIRNAME=/usr/bin/dirname
NB_GREP=/usr/bin/grep
NB_AWK=/usr/bin/awk
NB_SED=/usr/bin/sed
NB_HEAD=/usr/bin/head
NB_INSTALL=/usr/bin/install
NB_MKDIR=/usr/bin/mkdir
NB_MKTEMP=/usr/bin/mktemp
NB_MV=/usr/bin/mv
NB_RM=/usr/bin/rm
NB_RMDIR=/usr/bin/rmdir

# sha256 of every wrapper and unit shipped before the manifest existed
# (release 1.0.0). A match only ever permits replacing or removing the file.
# Closed list: every release from 1.1.0 on records a manifest.
NB_SHIPPED_SHAS=(
  # setup/earbuds
  1436d9267ce4bf4e377d54ff4f79b7c6e9b31f141939a9c8c3047ec523121268
  8b8c67f774b1683588bdbb7ecf38bf6bcbcd1f7bee8f5412c008f1bdd684dc34
  6292c4412085aefceda16b2213cfc98d6cb2eaac9b8577dc9fdc94eb1f2126f8
  7fcd69f2e5fd7145358adb5bfbde0308542bcd11f780fafe8081623f73986408
  # setup/earctl.service (ExecStart=%h/.local/bin/earctl ...)
  549b60883eb69893e7f8200c83e10b8852a0537c032ae0fe9cca82907aa55d58
)

nb_is_shipped_sha() {
  local s
  for s in "${NB_SHIPPED_SHAS[@]}"; do
    [[ $s == "$1" ]] && return 0
  done
  return 1
}

# ~/.cargo/bin/cargo is a rustup symlink by design: resolve it, require a regular file.
nb_cargo() {
  local c resolved
  for c in "$HOME/.cargo/bin/cargo" /usr/bin/cargo; do
    [[ -e $c ]] || continue
    resolved=$($NB_READLINK -f -- "$c" 2>/dev/null) || continue
    [[ -f $resolved && -x $resolved ]] || continue
    printf '%s\n' "$resolved"
    return 0
  done
  return 1
}

# ------------------------------------------------------------------ reporting

nb_err() { printf 'nothing-buds: %s\n' "$*" >&2; }

# Objects created so far this run, in creation order, as "type<TAB>path".
NB_RUN_ADDED=()
# Set when this run created the manifest, so rollback removes it too.
NB_MANIFEST_CREATED=0

# Undo this run's objects newest first, restoring backups. install.sh enables it.
NB_ROLLBACK_ENABLED=0

nb_rollback() {
  (( NB_ROLLBACK_ENABLED )) || return 0
  local i entry type path sha cur base
  for (( i = ${#NB_RUN_ADDED[@]} - 1; i >= 0; i-- )); do
    entry=${NB_RUN_ADDED[$i]}
    IFS=$'\t' read -r type path <<<"$entry"
    case $type in
      file)
        if [[ -L $path || ! -e $path ]]; then
          :
        else
          base=$($NB_BASENAME -- "$path")
          if [[ -f $NB_BACKUP_DIR/$base ]]; then
            $NB_MV -f -- "$NB_BACKUP_DIR/$base" "$path" 2>/dev/null || true
          else
            sha=$(nb_manifest_sha "$path")
            cur=$(nb_sha_file "$path" 2>/dev/null)
            if [[ -n $sha && $sha == "$cur" ]]; then
              $NB_RM -f -- "$path" 2>/dev/null || true
            fi
          fi
        fi
        ;;
      dir)
        $NB_RMDIR -- "$path" 2>/dev/null || true
        ;;
      pkg)
        nb_err "note: package '$path' was installed this run and is left in place"
        ;;
    esac
    nb_manifest_del "$type" "$path" 2>/dev/null || true
  done
  NB_RUN_ADDED=()
  if (( NB_MANIFEST_CREATED )); then
    $NB_RM -f -- "$NB_MANIFEST" 2>/dev/null || true
  fi
  $NB_RMDIR -- "$NB_BACKUP_DIR" 2>/dev/null || true
  $NB_RMDIR -- "$NB_STATE_DIR" 2>/dev/null || true
  return 0
}

nb_fail() {
  local code=$1
  shift
  nb_err "$*"
  nb_rollback
  exit "$code"
}

# ---------------------------------------------------------------- validators

nb_valid_addr() {
  [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

nb_valid_channel() {
  [[ $1 =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 63 ))
}

# ------------------------------------------------------------------ utilities

nb_sha_file() {
  local out
  out=$($NB_SHA -- "$1" 2>/dev/null) || return 1
  [[ -n $out ]] || return 1
  printf '%s\n' "${out%% *}"
}

# Read one line of at most $2 bytes from regular non-symlink $1 into $3.
# Returns 2 if more bytes follow the line, 1 if unreadable or empty.
nb_read_bounded() {
  local file=$1 max=$2 var=$3 line extra fd
  [[ -e $file && ! -L $file && -f $file ]] || return 1
  exec {fd}<"$file" || return 1
  IFS= read -r -n "$max" line <&"$fd" || true
  if IFS= read -r -n 1 extra <&"$fd"; then
    exec {fd}<&-
    return 2
  fi
  exec {fd}<&-
  [[ -n $line ]] || return 1
  printf -v "$var" '%s' "$line"
  return 0
}

# ------------------------------------------------------------------- manifest

# Third field of a record; empty for two-field records; 1 if absent.
nb_manifest_field() {
  [[ -r $NB_MANIFEST ]] || return 1
  local want="$1"$'\t'"$2" line rest
  while IFS=$'\t' read -r line; do
    [[ -n $line ]] || continue
    if [[ $line == "$want" || $line == "$want"$'\t'* ]]; then
      rest=${line#"$want"}
      rest=${rest#$'\t'}
      [[ -n $rest ]] && printf '%s\n' "$rest"
      return 0
    fi
  done <"$NB_MANIFEST"
  return 1
}

nb_manifest_sha() { nb_manifest_field file "$1"; }
nb_manifest_has() { nb_manifest_field "$1" "$2" >/dev/null; }

# Prints every path recorded under a type.
nb_manifest_paths() {
  [[ -r $NB_MANIFEST ]] || return 0
  local line rest
  while IFS=$'\t' read -r line; do
    [[ $line == "$1"$'\t'* ]] || continue
    rest=${line#"$1"$'\t'}
    printf '%s\n' "${rest%%$'\t'*}"
  done <"$NB_MANIFEST"
}

# Add or replace a record atomically; remembered for rollback.
nb_manifest_set() {
  local type=$1 path=$2 extra=${3:-} line want tmp
  [[ -d $NB_STATE_DIR ]] || { nb_err "internal: $NB_STATE_DIR does not exist"; return 6; }
  if [[ ! -e $NB_MANIFEST ]]; then
    NB_MANIFEST_CREATED=1
  fi
  want="$type"$'\t'"$path"
  tmp=$NB_STATE_DIR/.manifest.new.$$
  {
    if [[ -r $NB_MANIFEST ]]; then
      while IFS=$'\t' read -r line; do
        [[ -n $line ]] || continue
        [[ $line == "$want" || $line == "$want"$'\t'* ]] && continue
        printf '%s\n' "$line"
      done <"$NB_MANIFEST"
    fi
    if [[ -n $extra ]]; then
      printf '%s\t%s\t%s\n' "$type" "$path" "$extra"
    else
      printf '%s\t%s\n' "$type" "$path"
    fi
  } >"$tmp" || { $NB_RM -f -- "$tmp" 2>/dev/null; return 6; }
  $NB_MV -f -- "$tmp" "$NB_MANIFEST" 2>/dev/null || { $NB_RM -f -- "$tmp" 2>/dev/null; return 6; }
  NB_RUN_ADDED+=("$type"$'\t'"$path")
  return 0
}

nb_manifest_del() {
  local type=$1 path=$2 line want tmp
  [[ -r $NB_MANIFEST ]] || return 0
  want="$type"$'\t'"$path"
  tmp=$NB_STATE_DIR/.manifest.new.$$
  {
    while IFS=$'\t' read -r line; do
      [[ -n $line ]] || continue
      [[ $line == "$want" || $line == "$want"$'\t'* ]] && continue
      printf '%s\n' "$line"
    done <"$NB_MANIFEST"
  } >"$tmp" || { $NB_RM -f -- "$tmp" 2>/dev/null; return 6; }
  $NB_MV -f -- "$tmp" "$NB_MANIFEST" 2>/dev/null || { $NB_RM -f -- "$tmp" 2>/dev/null; return 6; }
  return 0
}

# ------------------------------------------------------------ directory walks

# mkdir -p that refuses symlinks and non-directories and records what it
# creates. Records are written after the walk: the manifest lives at its bottom.
nb_ensure_dir_chain() {
  local path=$1
  [[ $path == /* ]] || { nb_err "internal: not an absolute path: $path"; return 6; }
  local -a parts=() created=()
  IFS='/' read -r -a parts <<<"${path#/}"
  local part cur=""
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    cur="$cur/$part"
    if [[ -L $cur ]]; then
      nb_err "refusing to operate through symlink $cur"
      return 5
    fi
    if [[ -d $cur ]]; then
      continue
    fi
    if [[ -e $cur ]]; then
      nb_err "refusing to replace non-directory $cur"
      return 5
    fi
    $NB_MKDIR -- "$cur" 2>/dev/null || return 6
    created+=("$cur")
  done
  local d
  for d in "${created[@]}"; do
    nb_manifest_set dir "$d" || return 6
  done
  return 0
}

# ------------------------------------------------------------- install side

nb_backup_file() {
  local path=$1
  nb_ensure_dir_chain "$NB_BACKUP_DIR" || return $?
  $NB_CP -p -- "$path" "$NB_BACKUP_DIR/$($NB_BASENAME -- "$path")" 2>/dev/null || return 6
}

# Undo a publish whose manifest record failed: restore the backup or remove it.
nb_unpublish() {
  local dst=$1
  if [[ -f $NB_BACKUP_DIR/$($NB_BASENAME -- "$dst") ]]; then
    $NB_MV -f -- "$NB_BACKUP_DIR/$($NB_BASENAME -- "$dst")" "$dst" 2>/dev/null || true
  else
    $NB_RM -f -- "$dst" 2>/dev/null || true
  fi
}

# Copy $1 to $2 (mode $3) if $2 is ours or absent; refuse symlinks and
# foreign files; back up, publish atomically, record.
nb_install_file() {
  local src=$1 dst=$2 mode=$3
  if [[ -L $dst ]]; then
    nb_fail 5 "refusing to touch $dst: it is a symlink"
  fi
  local sha_src sha_cur rec owned=0
  sha_src=$(nb_sha_file "$src") || nb_fail 6 "cannot read $src"
  if [[ -e $dst ]]; then
    sha_cur=$(nb_sha_file "$dst") || nb_fail 6 "cannot read existing $dst"
    rec=$(nb_manifest_sha "$dst")
    if [[ -n $rec && $rec == "$sha_cur" ]] || [[ $sha_cur == "$sha_src" ]] || nb_is_shipped_sha "$sha_cur"; then
      owned=1
    fi
    if (( ! owned )) && (( ! NB_REPLACE_EXISTING )); then
      nb_fail 5 "refusing to replace $dst: pre-existing and not provably ours (pass --replace-existing to override)"
    fi
    nb_backup_file "$dst" || nb_fail 6 "could not back up $dst"
  fi
  nb_ensure_dir_chain "$($NB_DIRNAME -- "$dst")" || nb_fail $? "cannot prepare parent of $dst"
  local tmp
  tmp=$($NB_MKTEMP "$($NB_DIRNAME -- "$dst")/.$($NB_BASENAME -- "$dst").new.XXXXXX") || nb_fail 6 "could not stage $dst"
  $NB_INSTALL -m"$mode" -- "$src" "$tmp" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not stage $dst"; }
  $NB_MV -f -- "$tmp" "$dst" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not publish $dst"; }
  nb_manifest_set file "$dst" "$sha_src" || { nb_unpublish "$dst"; nb_fail 6 "could not record $dst"; }
}

# nb_install_file for a literal string.
nb_write_owned() {
  local dst=$1 mode=$2 content=$3
  if [[ -L $dst ]]; then
    nb_fail 5 "refusing to touch $dst: it is a symlink"
  fi
  local sha_cur rec owned=0 tmp sha_new
  if [[ -e $dst ]]; then
    sha_cur=$(nb_sha_file "$dst") || nb_fail 6 "cannot read existing $dst"
    rec=$(nb_manifest_sha "$dst")
    if [[ -n $rec && $rec == "$sha_cur" ]] || nb_is_shipped_sha "$sha_cur"; then
      owned=1
    fi
    if (( ! owned )) && (( ! NB_REPLACE_EXISTING )); then
      nb_fail 5 "refusing to replace $dst: pre-existing and not provably ours (pass --replace-existing to override)"
    fi
    nb_backup_file "$dst" || nb_fail 6 "could not back up $dst"
  fi
  nb_ensure_dir_chain "$($NB_DIRNAME -- "$dst")" || nb_fail $? "cannot prepare parent of $dst"
  tmp=$($NB_MKTEMP "$($NB_DIRNAME -- "$dst")/.$($NB_BASENAME -- "$dst").new.XXXXXX") || nb_fail 6 "could not stage $dst"
  printf '%s\n' "$content" >"$tmp" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not stage $dst"; }
  $NB_CHMOD "$mode" "$tmp" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not set mode on $dst"; }
  sha_new=$(nb_sha_file "$tmp") || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not hash $dst"; }
  $NB_MV -f -- "$tmp" "$dst" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not publish $dst"; }
  nb_manifest_set file "$dst" "$sha_new" || { nb_unpublish "$dst"; nb_fail 6 "could not record $dst"; }
}

# Create $1 only if nothing is there. 0 created, 1 exists, 2 is a symlink.
nb_write_if_absent() {
  local dst=$1 mode=$2 content=$3
  if [[ -L $dst ]]; then
    return 2
  fi
  if [[ -e $dst ]]; then
    return 1
  fi
  nb_ensure_dir_chain "$($NB_DIRNAME -- "$dst")" || nb_fail $? "cannot prepare parent of $dst"
  local tmp sha_new
  tmp=$($NB_MKTEMP "$($NB_DIRNAME -- "$dst")/.$($NB_BASENAME -- "$dst").new.XXXXXX") || nb_fail 6 "could not stage $dst"
  printf '%s\n' "$content" >"$tmp" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not stage $dst"; }
  $NB_CHMOD "$mode" "$tmp" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not set mode on $dst"; }
  sha_new=$(nb_sha_file "$tmp") || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not hash $dst"; }
  $NB_MV -f -- "$tmp" "$dst" 2>/dev/null || { $NB_RM -f -- "$tmp"; nb_fail 6 "could not publish $dst"; }
  nb_manifest_set file "$dst" "$sha_new" || { nb_unpublish "$dst"; nb_fail 6 "could not record $dst"; }
  return 0
}

# ------------------------------------------------------------ uninstall side

# Remove a recorded file only while its bytes still match and it is not a
# symlink. 0 removed or gone, 1 changed, 2 symlink, 6 failure.
nb_remove_owned_file() {
  local path=$1 sha=$2 cur
  if [[ -L $path ]]; then
    nb_err "leaving $path: it is a symlink now (we installed a regular file)"
    return 2
  fi
  if [[ ! -e $path ]]; then
    nb_manifest_del file "$path"
    return 0
  fi
  cur=$(nb_sha_file "$path") || return 6
  if [[ -n $sha && $cur != "$sha" ]]; then
    nb_err "leaving $path: content no longer matches what this plugin installed"
    return 1
  fi
  $NB_RM -f -- "$path" 2>/dev/null || return 6
  nb_manifest_del file "$path"
  return 0
}

# Remove a recorded directory only while empty. 0 removed or gone, 1 not empty, 2 symlink.
nb_remove_owned_dir() {
  local path=$1
  if [[ -L $path ]]; then
    nb_err "leaving $path: it is a symlink now (we created a directory)"
    return 2
  fi
  if [[ ! -d $path ]]; then
    nb_manifest_del dir "$path"
    return 0
  fi
  if ! $NB_RMDIR -- "$path" 2>/dev/null; then
    nb_err "leaving $path: not empty"
    return 1
  fi
  nb_manifest_del dir "$path"
  return 0
}
