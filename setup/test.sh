#!/bin/bash

# Evidence for the marketplace security review. Runs installer, uninstaller
# and wrapper inside a throwaway HOME with fake bluetoothctl/systemctl/yay/
# earctl: no real units, packages, network or root. coreutils, jq and
# /usr/bin/timeout stay real.
#
# Subject scripts are copied into a sandbox with two asserted edits: the
# fake-binary path constants, and one extra NB_SHIPPED_SHAS entry standing in
# for a wrapper an earlier release shipped.
#
# Run: bash setup/test.sh

set -uo pipefail

T=$(/usr/bin/mktemp -d) || exit 1
trap '/usr/bin/rm -rf -- "$T"' EXIT

FAILS=0
CHECKS=0

step() { printf '\n== %s\n' "$*"; }
ok()   { CHECKS=$((CHECKS+1)); printf '  ok   %s\n' "$*"; }
bad()  { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf '  FAIL %s\n' "$*"; }

assert_rc() { # desc want got
  if [[ $3 == $2 ]]; then ok "$1 (rc $3)"; else bad "$1 (rc $3, want $2)"; fi
}
assert_eq() { # desc got want
  if [[ $2 == $3 ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
assert_exists() { if [[ -e $2 || -L $2 ]]; then ok "$1 exists"; else bad "$1 missing ($2)"; fi }
assert_gone()   { if [[ ! -e $2 && ! -L $2 ]]; then ok "$1 gone"; else bad "$1 still present ($2)"; fi }
assert_line() { # desc pattern file
  if /usr/bin/grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (no match for '$2' in $3)"; fi
}
assert_no_line() { # desc pattern file
  if /usr/bin/grep -q -- "$2" "$3"; then bad "$1 (unexpected '$2' in $3)"; else ok "$1"; fi
}

SUBJ=$T/subject
FAKE=$T/fakebin
HN=0
H=""

new_home() {
  HN=$((HN+1))
  H=$T/home$HN
  /usr/bin/mkdir -p -- "$H"
}

run_install() { # -- install.sh args...
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    bash "$SUBJ/install.sh" "$@" </dev/null
}

run_uninstall() { # -- uninstall.sh args...
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    bash "$SUBJ/uninstall.sh" "$@" </dev/null
}

run_pty() { # script args... -- runs under a pty so consent prompts fire;
            # feeds "y" on stdin. Returns the child's exit code via -e.
  printf 'y\ny\ny\n' |
    env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
      /usr/bin/script -q -e -c "bash $SUBJ/$1 ${*:2}" /dev/null
}

wrap() { # wrapper args...
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    bash "$SUBJ/earbuds" "$@"
}

log() { /usr/bin/cat "$FAKE/log"; }
log_reset() { : >"$FAKE/log"; }
log_has() { /usr/bin/grep -q -- "$1" "$FAKE/log"; }

# ---------------------------------------------------------------- subject

step "preparing subject copies"
/usr/bin/mkdir -p -- "$SUBJ" "$FAKE"
for f in install.sh uninstall.sh lib.sh earbuds earctl.service; do
  /usr/bin/cp -- "setup/$f" "$SUBJ/$f"
done

# Point the subject at the fakes; the real timeout is the enforcement under test.
for f in lib.sh earbuds; do
  /usr/bin/sed -i \
    -e "s|^NB_BT=.*|NB_BT=$FAKE/bluetoothctl|" \
    -e "s|^NB_SYSTEMCTL=.*|NB_SYSTEMCTL=$FAKE/systemctl|" \
    -e "s|^NB_PACMAN=.*|NB_PACMAN=$FAKE/pacman|" \
    -e "s|^NB_YAY=.*|NB_YAY=$FAKE/yay|" \
    -e "s|^NB_EARCTL_FALLBACK=.*|NB_EARCTL_FALLBACK=$FAKE/earctl|" \
    "$SUBJ/$f"
done

assert_eq "lib.sh bluetoothctl rewritten" \
  "$(/usr/bin/grep -c "^NB_BT=$FAKE/bluetoothctl$" "$SUBJ/lib.sh")" "1"
assert_eq "lib.sh earctl fallback rewritten" \
  "$(/usr/bin/grep -c "^NB_EARCTL_FALLBACK=$FAKE/earctl$" "$SUBJ/lib.sh")" "1"
assert_eq "earbuds bluetoothctl rewritten" \
  "$(/usr/bin/grep -c "^NB_BT=$FAKE/bluetoothctl$" "$SUBJ/earbuds")" "1"
assert_eq "earbuds earctl fallback rewritten" \
  "$(/usr/bin/grep -c "^NB_EARCTL_FALLBACK=$FAKE/earctl$" "$SUBJ/earbuds")" "1"

# Stand-in for the 0.0.1 wrapper (its bytes are not in this repo).
printf '#!/bin/bash\n# legacy wrapper from a pre-manifest release\necho legacy\n' >"$FAKE/legacy-earbuds"
LEGACY_SHA=$(/usr/bin/sha256sum -- "$FAKE/legacy-earbuds" | /usr/bin/cut -d' ' -f1)
printf 'NB_SHIPPED_SHAS+=(%s)\n' "$LEGACY_SHA" >>"$SUBJ/lib.sh"
assert_eq "lib.sh legacy hash injected" \
  "$(/usr/bin/grep -c "^NB_SHIPPED_SHAS+=($LEGACY_SHA)$" "$SUBJ/lib.sh")" "1"

# The 0.0.1 unit, byte for byte; its hash is in lib.sh's list.
cat >"$FAKE/legacy-unit" <<'EOF_UNIT'
[Unit]
Description=earctl RFCOMM server for Nothing/CMF earbuds
PartOf=graphical-session.target
After=bluetooth.target

[Service]
Type=simple
ExecStart=%h/.local/bin/earctl server --addr 127.0.0.1:8787
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF_UNIT
assert_eq "legacy unit reproduces the 0.0.1 hash" \
  "$(/usr/bin/sha256sum -- "$FAKE/legacy-unit" | /usr/bin/cut -d' ' -f1)" \
  "549b60883eb69893e7f8200c83e10b8852a0537c032ae0fe9cca82907aa55d58"

for f in install.sh uninstall.sh lib.sh earbuds; do
  bash -n "$SUBJ/$f" || bad "syntax: $f"
done
ok "all subject scripts parse"

run_check() { # install.sh --check in the current home; prints nothing
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    bash "$SUBJ/install.sh" --check </dev/null >/dev/null 2>&1
}

# ---------------------------------------------------------------- fakes

cat >"$FAKE/bluetoothctl" <<EOF
#!/bin/bash
echo "bluetoothctl \$*" >> "$FAKE/log"
case \$1 in
  devices)
    if [[ -f "$FAKE/bt-devices" ]]; then
      /usr/bin/cat "$FAKE/bt-devices"
    else
      echo "Device AA:BB:CC:DD:EE:FF CMF Buds 2"
    fi ;;
  connect)    echo yes >"$FAKE/bt-connected" ;;
  disconnect) echo no  >"$FAKE/bt-connected" ;;
  info)
    echo "Name: CMF Buds 2"
    if [[ -f "$FAKE/bt-paired" && \$(/usr/bin/cat "$FAKE/bt-paired") == no ]]; then
      echo "Paired: no"
    else
      echo "Paired: yes"
    fi
    if [[ -f "$FAKE/bt-connected" && \$(/usr/bin/cat "$FAKE/bt-connected") == yes ]]; then
      echo "Connected: yes"
    else
      echo "Connected: no"
    fi ;;
esac
exit 0
EOF

cat >"$FAKE/earctl.real" <<'EOF'
#!/bin/bash
echo "earctl $*" >> "__FAKE__/log"
# Flag file: fail the first `anc get` so status reconnects and logs --channel.
if [[ $1 == anc && $2 == get && -f "__FAKE__/anc-fail-first" && ! -f "__FAKE__/anc-failed" ]]; then
  touch "__FAKE__/anc-failed"
  exit 1
fi
case $1 in
  anc)    if [[ $2 == get ]]; then echo '{"noise_cancellation":{"mode":"noise_cancellation","level":"high"}}'; fi ;;
  battery) echo '{"left":{"Level":{"percent":80,"charging":false}},"right":{"Level":{"percent":75,"charging":false}},"case":{"Level":{"percent":60,"charging":false}}}' ;;
  latency) if [[ $2 == get ]]; then echo '{"low_latency_enabled":false}'; fi ;;
  in-ear)  if [[ $2 == get ]]; then echo '{"detection_enabled":true}'; fi ;;
  ring)    /usr/bin/cat >/dev/null ;;
esac
exit 0
EOF

make_earctl() { # writes $FAKE/earctl pointing its log at $FAKE/log
  /usr/bin/sed "s|__FAKE__|$FAKE|g" "$FAKE/earctl.real" >"$FAKE/earctl"
  /usr/bin/chmod 755 "$FAKE/earctl"
}

cat >"$FAKE/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$FAKE/log"
if [[ -f "$FAKE/systemctl-fail-enable" && \$2 == enable ]]; then
  exit 1
fi
exit 0
EOF

cat >"$FAKE/yay" <<EOF
#!/bin/bash
echo "yay \$*" >> "$FAKE/log"
case \$1 in
  -S)   if [[ \$2 == --needed ]]; then
          /usr/bin/sed "s|__FAKE__|$FAKE|g" "$FAKE/earctl.real" > "$FAKE/earctl"
          /usr/bin/chmod 755 "$FAKE/earctl"
        fi ;;
  -Rns) /usr/bin/rm -f -- "$FAKE/earctl" ;;
esac
exit 0
EOF

cat >"$FAKE/pacman" <<EOF
#!/bin/bash
echo "pacman \$*" >> "$FAKE/log"
exit 0
EOF

for f in bluetoothctl systemctl yay pacman; do
  /usr/bin/chmod 755 "$FAKE/$f"
done

manifest_of() { echo "$H/.local/state/io.github.saiaungminkhant.nothing-buds/manifest"; }

# ============================================================= scenarios

step "S1: consent required without --yes, nothing touched"
new_home
log_reset
run_install
rc=$?
assert_rc "no --yes, non-tty" 4 "$rc"
assert_gone "wrapper" "$H/.local/bin/earbuds"
assert_gone "unit" "$H/.config/systemd/user/earctl.service"
assert_gone "state dir" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"
assert_no_line "no systemctl calls" "systemctl" "$FAKE/log"

step "S1b: declined consent in a terminal, nothing touched"
new_home
log_reset
printf 'n\n' |
  env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    /usr/bin/script -q -e -c "bash $SUBJ/install.sh" /dev/null
rc=$?
assert_rc "declined in pty" 4 "$rc"
assert_gone "wrapper" "$H/.local/bin/earbuds"

step "S2: fresh install with earctl already present (AUR-style)"
new_home
log_reset
make_earctl
run_install --yes
rc=$?
assert_rc "install" 0 "$rc"
assert_exists "wrapper" "$H/.local/bin/earbuds"
assert_exists "unit" "$H/.config/systemd/user/earctl.service"
assert_exists "config" "$H/.config/earbuds/address"
assert_eq "pinned address" "$(/usr/bin/cat "$H/.config/earbuds/address")" "AA:BB:CC:DD:EE:FF"
assert_line "unit execs the resolved earctl" \
  "^ExecStart=$FAKE/earctl server --addr 127.0.0.1:8787\$" "$H/.config/systemd/user/earctl.service"
assert_no_line "no placeholder left in the unit" "%EARCTL%" "$H/.config/systemd/user/earctl.service"
assert_eq "earctl-bin records the AUR path" "$(/usr/bin/cat "$H/.local/state/io.github.saiaungminkhant.nothing-buds/earctl-bin")" "$FAKE/earctl"
M=$(manifest_of)
assert_line "manifest records wrapper" "file$(/usr/bin/printf '\t')$H/.local/bin/earbuds" "$M"
assert_line "manifest records unit" "file$(/usr/bin/printf '\t')$H/.config/systemd/user/earctl.service" "$M"
assert_line "manifest records pre-existing earctl" "pre$(/usr/bin/printf '\t')$FAKE/earctl" "$M"
assert_line "daemon-reload ran" "systemctl --user daemon-reload" "$FAKE/log"
assert_line "unit enabled" "systemctl --user enable --now earctl.service" "$FAKE/log"
assert_no_line "yay never invoked" "yay" "$FAKE/log"
assert_no_line "pacman never invoked" "pacman" "$FAKE/log"

step "S3: uninstall after S2 removes exactly what the manifest owns"
log_reset
run_uninstall --yes
rc=$?
assert_rc "uninstall" 0 "$rc"
assert_gone "wrapper" "$H/.local/bin/earbuds"
assert_gone "unit" "$H/.config/systemd/user/earctl.service"
assert_gone "config dir (we created it, now empty)" "$H/.config/earbuds"
assert_gone "state dir" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"
assert_exists "pre-existing earctl untouched" "$FAKE/earctl"
assert_line "service stopped" "systemctl --user disable --now earctl.service" "$FAKE/log"
assert_no_line "no package-manager removal" "-Rns" "$FAKE/log"
assert_no_line "pacman -Qoq never used" "-Qoq" "$FAKE/log"

step "S4: exit 2 without a terminal when earctl is missing; nothing else changes"
new_home
log_reset
/usr/bin/rm -f -- "$FAKE/earctl"
run_install --yes
rc=$?
assert_rc "earctl missing, non-tty" 2 "$rc"
assert_gone "wrapper not installed" "$H/.local/bin/earbuds"
assert_gone "unit not installed" "$H/.config/systemd/user/earctl.service"
assert_gone "state dir rolled back" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"

step "S5: interactive terminal install: consent + AUR earctl + full install"
new_home
log_reset
/usr/bin/rm -f -- "$FAKE/earctl"
run_pty install.sh
rc=$?
assert_rc "consented terminal install" 0 "$rc"
assert_exists "wrapper" "$H/.local/bin/earbuds"
assert_exists "unit" "$H/.config/systemd/user/earctl.service"
assert_exists "earctl via yay" "$FAKE/earctl"
M=$(manifest_of)
assert_line "manifest records the package" "pkg$(printf '\t')earctl" "$M"
assert_line "yay installed earctl" "yay -S --needed earctl" "$FAKE/log"

step "S5b: uninstall removes the recorded package; --keep-earctl keeps it"
log_reset
run_uninstall --yes
rc=$?
assert_rc "uninstall with package" 0 "$rc"
assert_gone "earctl package removed" "$FAKE/earctl"
assert_line "package removed through yay" "yay -Rns earctl" "$FAKE/log"
assert_gone "state dir" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"

new_home
log_reset
/usr/bin/rm -f -- "$FAKE/earctl"
run_pty install.sh
rc=$?
assert_rc "second terminal install" 0 "$rc"
log_reset
run_uninstall --yes --keep-earctl
rc=$?
assert_rc "uninstall keeping earctl" 0 "$rc"
assert_exists "earctl kept" "$FAKE/earctl"
assert_no_line "no package removal attempted" "-Rns" "$FAKE/log"

step "S6: pre-existing symlink at the wrapper path is refused, not followed"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.local/bin"
echo "do not touch" >"$T/victim.txt"
/usr/bin/ln -s -- "$T/victim.txt" "$H/.local/bin/earbuds"
run_install --yes
rc=$?
assert_rc "symlink refused" 5 "$rc"
assert_eq "victim untouched" "$(/usr/bin/cat "$T/victim.txt")" "do not touch"
assert_exists "symlink left as-is" "$H/.local/bin/earbuds"
assert_gone "unit not installed after refusal" "$H/.config/systemd/user/earctl.service"

step "S7: pre-existing foreign file at the unit path is refused; --replace-existing replaces it with a backup"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.config/systemd/user"
echo "foreign unit" >"$H/.config/systemd/user/earctl.service"
run_install --yes
rc=$?
assert_rc "foreign unit refused" 5 "$rc"
assert_eq "foreign unit untouched" "$(/usr/bin/cat "$H/.config/systemd/user/earctl.service")" "foreign unit"

log_reset
run_install --yes --replace-existing
rc=$?
assert_rc "replace-existing proceeds" 0 "$rc"
assert_line "unit now ours (rendered)" \
  "^ExecStart=$FAKE/earctl server --addr 127.0.0.1:8787\$" "$H/.config/systemd/user/earctl.service"
assert_exists "old copy backed up" \
  "$H/.local/state/io.github.saiaungminkhant.nothing-buds/backup/earctl.service"
assert_eq "backup holds the foreign content" \
  "$(/usr/bin/cat "$H/.local/state/io.github.saiaungminkhant.nothing-buds/backup/earctl.service")" "foreign unit"

step "S8: pre-existing config dir with a foreign file is respected"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.config/earbuds"
echo 12 >"$H/.config/earbuds/channel"
run_install --yes
rc=$?
assert_rc "install with foreign config dir" 0 "$rc"
assert_exists "foreign channel file" "$H/.config/earbuds/channel"
assert_exists "our address file" "$H/.config/earbuds/address"
log_reset
run_uninstall --yes
rc=$?
assert_rc "uninstall leaves foreign file" 0 "$rc"
assert_exists "foreign channel file survives" "$H/.config/earbuds/channel"
assert_gone "our address file removed" "$H/.config/earbuds/address"
assert_exists "config dir survives (not empty)" "$H/.config/earbuds"

step "S9: failed enable rolls everything back"
new_home
log_reset
make_earctl
touch "$FAKE/systemctl-fail-enable"
run_install --yes
rc=$?
assert_rc "enable failure" 6 "$rc"
/usr/bin/rm -f -- "$FAKE/systemctl-fail-enable"
assert_gone "wrapper rolled back" "$H/.local/bin/earbuds"
assert_gone "unit rolled back" "$H/.config/systemd/user/earctl.service"
assert_gone "address rolled back" "$H/.config/earbuds/address"
assert_gone "config dir rolled back" "$H/.config/earbuds"
assert_gone "state dir rolled back" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"
assert_line "disable ran after failed enable" "systemctl --user disable earctl.service" "$FAKE/log"
assert_exists "pre-existing earctl untouched" "$FAKE/earctl"

step "S10: double install is idempotent and keeps exactly one backup"
new_home
log_reset
make_earctl
run_install --yes
assert_rc "first install" 0 "$?"
run_install --yes
assert_rc "second install" 0 "$?"
M=$(manifest_of)
assert_eq "no duplicate wrapper record" \
  "$(/usr/bin/grep -c "file$(printf '\t')$H/.local/bin/earbuds$(printf '\t')" "$M")" "1"
assert_exists "backup of first wrapper" \
  "$H/.local/state/io.github.saiaungminkhant.nothing-buds/backup/earbuds"

step "S11: uninstall refuses a wrapper the user has modified"
log_reset
echo "tampered" >"$H/.local/bin/earbuds"
run_uninstall --yes
rc=$?
assert_rc "modified wrapper leaves partial exit" 6 "$rc"
assert_eq "tampered wrapper left alone" "$(/usr/bin/cat "$H/.local/bin/earbuds")" "tampered"

step "S12: legacy uninstall (no manifest) removes only content matches"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.local/bin" "$H/.config/systemd/user" "$H/.config/earbuds"
/usr/bin/cp -- "$SUBJ/earbuds" "$H/.local/bin/earbuds"
/usr/bin/cp -- "$FAKE/legacy-unit" "$H/.config/systemd/user/earctl.service"
echo 16 >"$H/.config/earbuds/channel"
run_uninstall --yes
rc=$?
assert_rc "legacy uninstall" 0 "$rc"
assert_gone "legacy wrapper (content matched)" "$H/.local/bin/earbuds"
assert_gone "legacy 0.0.1 unit (hash matched)" "$H/.config/systemd/user/earctl.service"
assert_exists "legacy config left alone" "$H/.config/earbuds/channel"
assert_exists "legacy earctl left alone" "$FAKE/earctl"

new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.local/bin"
/usr/bin/cp -- "$SUBJ/earbuds" "$H/.local/bin/earbuds"
echo "someone else's wrapper" >"$H/.local/bin/earbuds"
run_uninstall --yes
rc=$?
assert_rc "foreign wrapper refused in legacy mode" 6 "$rc"
assert_eq "foreign wrapper kept" "$(/usr/bin/cat "$H/.local/bin/earbuds")" "someone else's wrapper"

step "S13: hung helpers cannot wedge the wrapper; every call is bounded"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.config/earbuds"
echo "AA:BB:CC:DD:EE:FF" >"$H/.config/earbuds/address"

t0=$SECONDS
out=$(wrap status)
rc=$?
cost=$((SECONDS - t0))
assert_rc "status with live fakes" 0 "$rc"
assert_eq "status JSON connected" \
  "$(echo "$out" | /usr/bin/jq -r .connected)" "false"

echo yes >"$FAKE/bt-connected"
t0=$SECONDS
out=$(wrap status)
cost=$((SECONDS - t0))
assert_rc "connected status" 0 "$rc"
assert_eq "battery left" "$(echo "$out" | /usr/bin/jq -r .left)" "80"
assert_eq "battery case" "$(echo "$out" | /usr/bin/jq -r .case)" "60"
assert_eq "in-ear read" "$(echo "$out" | /usr/bin/jq -r .in_ear)" "true"

# Hung bluetoothctl that forks a grandchild holding the pipe: timeout signals
# the whole group, so head sees EOF within the deadline.
cat >"$FAKE/bluetoothctl" <<'EOF'
#!/bin/bash
/usr/bin/sleep 3210 &
/usr/bin/sleep 3210
EOF
/usr/bin/chmod 755 "$FAKE/bluetoothctl"
t0=$SECONDS
out=$(wrap status)
rc=$?
cost=$((SECONDS - t0))
assert_rc "status survives a hung bluetoothctl" 0 "$rc"
if (( cost <= 30 )); then ok "hung helper bounded (${cost}s)"; else bad "hung helper took ${cost}s"; fi
/usr/bin/sleep 1
if /usr/bin/pgrep -f 'sleep 3210' >/dev/null; then
  bad "hung helper's grandchild survived the deadline"
  /usr/bin/pkill -f 'sleep 3210'
else
  ok "hung helper's grandchild reaped with it"
fi

# A bluetoothctl that spews without end: the read is byte-capped.
cat >"$FAKE/bluetoothctl" <<'EOF'
#!/bin/bash
while :; do echo "Device AA:BB:CC:DD:EE:FF CMF Buds 2 spam"; done
EOF
/usr/bin/chmod 755 "$FAKE/bluetoothctl"
t0=$SECONDS
out=$(wrap status)
rc=$?
cost=$((SECONDS - t0))
assert_rc "status survives a noisy bluetoothctl" 0 "$rc"
if (( cost <= 20 )); then ok "noisy helper bounded (${cost}s)"; else bad "noisy helper took ${cost}s"; fi

# Restore the well-behaved fake for later scenarios.
cat >"$FAKE/bluetoothctl" <<EOF
#!/bin/bash
echo "bluetoothctl \$*" >> "$FAKE/log"
case \$1 in
  devices) echo "Device AA:BB:CC:DD:EE:FF CMF Buds 2" ;;
  connect)    echo yes >"$FAKE/bt-connected" ;;
  disconnect) echo no  >"$FAKE/bt-connected" ;;
  info)
    echo "Name: CMF Buds 2"
    echo "Paired: yes"
    if [[ -f "$FAKE/bt-connected" && \$(/usr/bin/cat "$FAKE/bt-connected") == yes ]]; then
      echo "Connected: yes"
    else
      echo "Connected: no"
    fi ;;
esac
exit 0
EOF
/usr/bin/chmod 755 "$FAKE/bluetoothctl"

# The exact timeout shape Panel.qml runs, killing a stuck helper and its group.
cat >"$FAKE/hang-with-child" <<EOF
#!/bin/bash
"$FAKE/child-sleep" &
sleep 300
EOF
cat >"$FAKE/child-sleep" <<'EOF'
#!/bin/bash
sleep 300
EOF
/usr/bin/chmod 755 "$FAKE/hang-with-child" "$FAKE/child-sleep"
t0=$SECONDS
/usr/bin/timeout --kill-after=5 3 "$FAKE/hang-with-child" >/dev/null 2>&1
rc=$?
cost=$((SECONDS - t0))
assert_rc "panel-shaped deadline kills a stuck helper" 124 "$rc"
/usr/bin/sleep 2
if /usr/bin/pgrep -f "$FAKE/child-sleep" >/dev/null; then
  bad "process group was not cleaned up"
else
  ok "process group cleaned up"
fi

step "S14: inputs are validated before they reach any command"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.config/earbuds"
echo "AA:BB:CC:DD:EE:FF" >"$H/.config/earbuds/address"

log_reset
wrap --address "--evil-injection" status
rc=$?
assert_rc "option-looking address rejected" 64 "$rc"
assert_no_line "rejected address never reached bluetoothctl" "--evil-injection" "$FAKE/log"

log_reset
wrap --channel 99 status
rc=$?
assert_rc "out-of-range channel rejected" 64 "$rc"

log_reset
touch "$FAKE/anc-fail-first" "$FAKE/bt-connected"
wrap --address "AA:BB:CC:DD:EE:FF" --channel 16 status
rc=$?
/usr/bin/rm -f -- "$FAKE/anc-fail-first" "$FAKE/anc-failed"
assert_rc "valid overrides accepted" 0 "$rc"
assert_line "override address reached the command" \
  "bluetoothctl info AA:BB:CC:DD:EE:FF" "$FAKE/log"
assert_line "override channel reached the command" \
  "--channel 16" "$FAKE/log"

# A giant address file is refused by the size bound, not read.
/usr/bin/head -c 10000 /dev/zero | /usr/bin/tr '\0' 'x' >"$H/.config/earbuds/address"
log_reset
wrap status >/dev/null 2>&1
assert_line "fell back to detection after oversized file" \
  "bluetoothctl info AA:BB:CC:DD:EE:FF" "$FAKE/log"

# A symlinked address file is never read through.
echo "11:22:33:44:55:66" >"$T/addr-target"
/usr/bin/rm -f -- "$H/.config/earbuds/address"
/usr/bin/ln -s -- "$T/addr-target" "$H/.config/earbuds/address"
log_reset
wrap status >/dev/null 2>&1
assert_line "symlinked config refused, detection used instead" \
  "bluetoothctl info AA:BB:CC:DD:EE:FF" "$FAKE/log"

# A garbage channel file is ignored in favour of the default.
/usr/bin/rm -f -- "$H/.config/earbuds/address"
echo "banana" >"$H/.config/earbuds/channel"
log_reset
touch "$FAKE/anc-fail-first" "$FAKE/bt-connected"
wrap --address "AA:BB:CC:DD:EE:FF" status >/dev/null 2>&1
/usr/bin/rm -f -- "$FAKE/anc-fail-first" "$FAKE/anc-failed"
assert_line "invalid channel file ignored, default 16 used" \
  "--channel 16" "$FAKE/log"

step "S15: the panel's probe (install.sh --check) is read-only and exact"
new_home
log_reset
make_earctl
run_check
assert_rc "fresh home is not set up" 1 "$?"
assert_gone "--check created no state dir" "$H/.local/state/io.github.saiaungminkhant.nothing-buds"
assert_gone "--check created no wrapper" "$H/.local/bin/earbuds"
assert_no_line "--check ran no systemctl" "systemctl" "$FAKE/log"

run_install --yes
assert_rc "install" 0 "$?"
run_check
assert_rc "installed home is set up" 0 "$?"

echo "tampered" >>"$H/.local/bin/earbuds"
run_check
assert_rc "an outdated or edited wrapper is not set up" 1 "$?"
/usr/bin/cp -- "$SUBJ/earbuds" "$H/.local/bin/earbuds"
run_check
assert_rc "restored wrapper is set up again" 0 "$?"

/usr/bin/rm -f -- "$H/.local/bin/earbuds"
/usr/bin/ln -s -- "$SUBJ/earbuds" "$H/.local/bin/earbuds"
run_check
assert_rc "a symlinked wrapper is not set up, even to the right bytes" 1 "$?"

/usr/bin/rm -f -- "$H/.local/bin/earbuds"
/usr/bin/cp -- "$SUBJ/earbuds" "$H/.local/bin/earbuds"
/usr/bin/rm -f -- "$FAKE/earctl"
run_check
assert_rc "missing earctl is not set up" 1 "$?"
make_earctl

step "S16: upgrade from a pre-manifest install is recognised, not refused"
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.local/bin" "$H/.config/systemd/user" "$H/.config/earbuds"
/usr/bin/install -m755 -- "$FAKE/legacy-earbuds" "$H/.local/bin/earbuds"
/usr/bin/cp -- "$FAKE/legacy-unit" "$H/.config/systemd/user/earctl.service"
echo "11:22:33:44:55:66" >"$H/.config/earbuds/address"
run_check
assert_rc "legacy install reads as not set up (wrapper outdated)" 1 "$?"

run_install --yes
rc=$?
assert_rc "upgrade install" 0 "$rc"
assert_eq "wrapper replaced with the current one" \
  "$(/usr/bin/cmp -s "$H/.local/bin/earbuds" "$SUBJ/earbuds" && echo same)" "same"
assert_eq "legacy wrapper backed up" \
  "$(/usr/bin/cmp -s "$H/.local/state/io.github.saiaungminkhant.nothing-buds/backup/earbuds" "$FAKE/legacy-earbuds" && echo same)" "same"
assert_line "unit re-rendered" \
  "^ExecStart=$FAKE/earctl server --addr 127.0.0.1:8787\$" "$H/.config/systemd/user/earctl.service"
assert_eq "legacy unit backed up" \
  "$(/usr/bin/cmp -s "$H/.local/state/io.github.saiaungminkhant.nothing-buds/backup/earctl.service" "$FAKE/legacy-unit" && echo same)" "same"
assert_eq "user's pinned address untouched" "$(/usr/bin/cat "$H/.config/earbuds/address")" "11:22:33:44:55:66"
M=$(manifest_of)
assert_line "config dir recorded as pre-existing" "pre$(printf '\t')$H/.config/earbuds" "$M"
assert_no_line "address file not claimed" "$H/.config/earbuds/address" "$M"
run_check
assert_rc "upgraded home is set up" 0 "$?"

log_reset
run_uninstall --yes
rc=$?
assert_rc "uninstall after upgrade" 0 "$rc"
assert_gone "wrapper" "$H/.local/bin/earbuds"
assert_gone "unit" "$H/.config/systemd/user/earctl.service"
assert_exists "pre-existing config dir kept" "$H/.config/earbuds"
assert_exists "user's address file kept" "$H/.config/earbuds/address"
assert_exists "pre-existing earctl kept" "$FAKE/earctl"

# A foreign wrapper that merely LOOKS legacy (different bytes) is still refused.
new_home
log_reset
make_earctl
/usr/bin/mkdir -p -- "$H/.local/bin"
printf '#!/bin/bash\necho not ours\n' >"$H/.local/bin/earbuds"
/usr/bin/chmod 755 "$H/.local/bin/earbuds"
run_install --yes
assert_rc "unknown wrapper bytes still refused" 5 "$?"
assert_eq "foreign wrapper untouched" "$(/usr/bin/tail -n1 "$H/.local/bin/earbuds")" "echo not ours"

# ------------------------------------------------------------------ verdict

printf '\n'
if (( FAILS )); then
  printf '%d checks, %d FAILED\n' "$CHECKS" "$FAILS"
  exit 1
fi
printf '%d checks, all passed\n' "$CHECKS"
exit 0
