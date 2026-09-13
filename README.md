# Nothing Buds

ANC, battery and playback controls for Nothing and CMF earbuds, as an Omarchy
bar widget.

<img src="preview.png" alt="The panel on a dark and a light Omarchy theme" width="720">

The panel follows your Omarchy theme. Both shots are the same build, on CMF
Buds 2.

- A dot on the bar icon carries the mode. Filled for ANC, hollow for
  transparency, drained when off or disconnected.
- Noise control: off, transparency, and ANC at low, mid, high or adaptive.
- Per-bud and case battery. The meter turns urgent below 20% and pulses while
  charging.
- Low lag mode and in-ear detection.
- Ultra bass with five levels, and spatial audio, on CMF Buds 2 and Nothing
  Ear (3). Super Mic on Ear (3). The panel shows what the model reports.
- Audio codec, switched through PipeWire. Switching interrupts playback for a
  few seconds while the link renegotiates.
- Connect and disconnect the buds from the panel header.
- Find my buds. It asks first, since the tone is loud enough to hurt a bud
  still in an ear. The tone stops itself after 8 seconds.

Developed against CMF Buds 2 (B179). Other Nothing and CMF models speak the
same protocol on a different RFCOMM channel. The panel probes for the right
one when the buds stay silent, and that is how Nothing Ear (3) works with it.
See [RFCOMM channel](#rfcomm-channel).

## Requirements

| | |
|---|---|
| [earctl](https://github.com/DaanHessen/earctl) | Speaks the Nothing RFCOMM protocol. AGPL-3.0. This plugin calls it as a separate program over its local HTTP API and does not bundle it. Setup builds missing earctl from an exact pinned commit, using its Cargo.lock |
| `bluez-utils` | `bluetoothctl`, for link state and connect/disconnect |
| `jq` | The wrapper builds its JSON output with it |

Dependencies are invoked by absolute path (`/usr/bin/bluetoothctl`,
`/usr/bin/jq`, `/usr/bin/earctl` or the recorded one below, `omarchy-launch-tui`
at `/usr/bin/omarchy-launch-tui`), never through PATH and never through an
environment override. If your distribution puts them somewhere else, symlink
or adjust with full knowledge of that fact.

## Install

```sh
omarchy plugin add https://github.com/SaiAungMinKhant/omarchy-nothing-buds.git --enable
```

**Setup only ever runs from a click.** Enabling the plugin never modifies
anything by itself. The panel opens with a short list of what setup installs
and a "Set up now" button. The click is the consent. The panel then runs
`setup/install.sh --yes`.

What that click installs:

- the `earbuds` wrapper into `~/.local/bin`,
- `earctl.service`, a systemd **user** service that keeps the RFCOMM session
  open,
- a pinned earbuds address in `~/.config/earbuds`,
- earctl itself, if it is not already on the machine, or a rebuild of one
  this plugin built from an older pin.

Nothing runs as root and installation never asks for a password. If earctl is
missing, or was built by this plugin from an older pin, setup stops and the
panel offers an "Install earctl" button that opens a terminal, where the
installer prints its plan and asks `Proceed? [y/N]` before doing anything. Have Git, a Rust toolchain (Cargo),
and the native build dependencies for earctl available first.

Missing earctl is always built from commit
`1315bfbf07eb74b946606e30ede2d4290449082f`, upstream master as of
2026-09-13 with Ear (3), Super Mic, spatial audio and CMF Buds 2 support.
Setup fetches that exact commit, checks it out detached, verifies HEAD, and
runs `cargo build --release --locked` so dependency resolution must match the
committed lockfile. The binary goes into `~/.local/bin/earctl` and the commit
is recorded next to the manifest. When a later version of this plugin moves
the pin, setup sees the recorded commit no longer matches and rebuilds, in a
terminal. Setup never installs an AUR package, even when `yay` is available.
An existing earctl is reused as a user-provided dependency and never rebuilt.
If it predates the pinned commit, the extra controls stay hidden until you
update it yourself.

Every file is written by temp file and rename, never through a symlink,
recorded in a manifest at
`~/.local/state/io.github.saiaungminkhant.nothing-buds/`, and backed up before
replacement. A pre-existing file counts as ours only when the manifest
records it or it is byte-identical to a version this plugin ships or has
shipped. Anything else is refused with exit 5 rather than overwritten.
`--replace-existing` overrides that for a human who wants it, keeping the old
copy in the `backup/` directory.

The panel decides whether to offer setup by running `install.sh --check`,
which exits 0 only when the wrapper is present and byte-identical to the one
in the plugin folder, the unit exists, earctl is found, and an earctl this
plugin built matches the pinned commit. It changes nothing and asks nothing.

Installer exit codes: `0` done · `1` (`--check` only) missing or out of date ·
`2` earctl missing or built from an older pin, needs a terminal · `3` base dependency missing · `4`
consent not given · `5` pre-existing object refused · `6` operational failure
(everything rolled back).

You can also run the installer directly:

```sh
~/.config/omarchy/plugins/io.github.saiaungminkhant.nothing-buds/setup/install.sh
```

Run by hand it prints its plan and asks before proceeding, and installs earctl
too, since it has a terminal to work with. A failed run rolls back everything
it did, restoring backups.

**Upgrading from version 0.0.1**, before the manifest existed, the panel
shows "Set up now" again, because the installed wrapper is out of date. The
installer recognises the old wrapper and unit by hash (`NB_SHIPPED_SHAS` in
`setup/lib.sh`), so the click replaces them with backups and records a
manifest; your pinned address and any earctl already on the machine are left
as they are and marked pre-existing, so a later uninstall will not touch them.

## Uninstall

```sh
~/.config/omarchy/plugins/io.github.saiaungminkhant.nothing-buds/setup/uninstall.sh
omarchy plugin remove io.github.saiaungminkhant.nothing-buds
```

Run them in that order. `omarchy plugin remove` deletes the plugin folder and
nothing else, and the uninstall script lives inside it.

The uninstall is manifest-driven. It removes exactly the objects recorded at
install time, and only while they are still provably ours, meaning the same
recorded hash and not currently a symlink. Files you edited are left alone, directories
are removed only when empty, and an earctl this plugin never installed is
never touched. The manifest itself and the backups go too.

The built earctl binary is removed by exact recorded path and hash, along
with the record of the commit it was built from. For
compatibility with version 0.0.2, an earctl package recorded by that version
is still removed through the package manager (`yay -Rns`, which may ask for
a password). New installations never create package records. Pass
`--keep-earctl` if something else on your system uses it.

Installs made before the manifest existed get the safe subset: only the
wrapper and unit are removed, and only if their content still matches a
version this plugin ships or has shipped. Everything else is listed for manual
cleanup.

## Configuration

The wrapper resolves your earbuds' address in this order: `--address`, then
`~/.config/earbuds/address`, then the first paired device whose name looks
like a Nothing or CMF product. `install.sh` writes the config file for you.
The RFCOMM channel resolves the same way (`--channel`, then
`~/.config/earbuds/channel`, then the one discovery found in
`~/.local/state/io.github.saiaungminkhant.nothing-buds/channel`, else 16).
Values are validated. An address must match `AA:BB:CC:DD:EE:FF` and a
channel must be 1 to 63. Anything that fails is ignored with a note rather
than passed to a command.

To pin per-widget instead, add keys to this widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.saiaungminkhant.nothing-buds", "address": "AA:BB:CC:DD:EE:FF", "channel": 16 }
```

The panel validates these too and shows "Ignoring invalid address/channel in
shell.json" if one fails the grammar, instead of building a command with them.
The `EARBUDS_ADDR`, `EARBUDS_CHANNEL` and `EARCTL` environment variables from
the first release are gone. An environment variable can steer which
executable runs or what it reads, and this plugin no longer has any such
path.

### RFCOMM channel

earctl finds the channel with `sdptool`. Arch no longer ships it, and it now
lives in AUR `bluez-utils-compat`, so the wrapper defaults to 16 instead.
Other models listen elsewhere:

| Model | RFCOMM channel | Confirmed by |
|---|---|---|
| CMF Buds 2 (B179) | 16 | me |
| Nothing Ear (3) (B173) | 15 | [@kasemeyer](https://github.com/SaiAungMinKhant/omarchy-nothing-buds/issues/2) |

A wrong channel does not fail loudly. The link opens and the buds never
answer. When the panel sees that twice in a row on a live link, it runs
`earbuds discover-channel`, which tries the known channels first and then 1
to 30, and accepts only a channel that returns a battery reading. Accepting
the link is not proof. On my CMF Buds 2 five channels opened and four of them
stayed quiet. The panel shows which channel it is trying, then "Found your
earbuds on channel N". The answer is remembered in
`~/.local/state/io.github.saiaungminkhant.nothing-buds/channel`, which the
wrapper reads after `~/.config/earbuds/channel` and uninstall removes.

Discovery runs once per link and never when a channel is pinned in
`shell.json` or `~/.config/earbuds/channel`. A pinned channel that stays
silent is reported instead. Every probe has a deadline, 5s to disconnect, 8s
to connect and 8s to read, so a device that answers nowhere costs about ten
minutes and a known model a few seconds. You can run it by hand too:

```sh
earbuds discover-channel
```

If your model is not in the table and discovery found it, please open an
issue with the model and channel.

## What is not here

None of these are hardware limits. The Nothing X app drives both on the
same earbuds.

| | |
|---|---|
| Equalizer | `eq get` always reads back mode 0 on CMF Buds 2, whatever the app shows, so the preset ids are unmapped |
| Gestures | earctl decodes them now (`earctl gestures get`), but the panel has no gesture editor |

## Security

The marketplace review requirements are addressed here:

| Requirement | Mechanism |
|---|---|
| Dependency installation must use the reviewed source | Missing earctl is built only from the full commit above, with detached checkout and HEAD verification before Cargo runs. `--locked` requires the committed dependency lockfile. The built commit is recorded, so a moved pin rebuilds rather than keeping an older binary. There is no AUR installation path. S5, S5a, S5c |
| Setup must be an explicit, consented action; no overwriting objects the plugin cannot prove it owns | Setup runs only from the panel's "Set up" click (`--yes`) or a y/N prompt in a terminal. `setup/lib.sh` installs through `nb_install_file`: symlinked targets are refused, pre-existing files are refused unless recorded in the manifest or byte-identical to a version shipped here, replaced files are backed up, and everything is published by atomic rename. The panel only ever probes with `install.sh --check`, which is read-only. `bash setup/test.sh` S1, S6, S7, S9, S15, S16 |
| Uninstall must remove only what this installation created | A manifest at `~/.local/state/io.github.saiaungminkhant.nothing-buds/` records every file, directory and package created. Removal is hash-checked, symlink-checked, empty-dir-only, and never recurses by inference. Legacy installs get content-matching only. S3, S8, S11, S12 |
| Helper calls need deadlines and output caps; a hung or noisy helper must not wedge the panel | Every wrapper call is wrapped in `/usr/bin/timeout` with byte caps on consumed output, and each helper runs in its own process group so a forked grandchild dies with it; the panel wraps every operation in `/usr/bin/timeout --kill-after=5 <deadline>`, streams stdout/stderr through capped parsers, and a watchdog plus supersession rules guarantee `busy`/link state always clears. Channel discovery is a fixed list of bounded probes, writes only inside the plugin's own state directory by temp file and rename, and refuses a symlink there. S13, S17 |
| Executable identity and input boundaries must not be steerable | All binaries are invoked by absolute path; the `EARCTL`/`EARBUDS_ADDR`/`EARBUDS_CHANNEL` overrides are removed; the panel passes overrides as validated arguments; config files are read bounded, without following symlinks, and validated against a Bluetooth-address grammar before use. S14 |

`setup/test.sh` runs all of this against fakes in a throwaway HOME, with no
root, no network and no real systemd, and is the evidence for the table above.

## Notes

Only one program can hold the Nothing RFCOMM socket at a time. BudsLink,
ear-web and this plugin will fight over it. Stop the service before you run
another one:

```sh
systemctl --user stop earctl.service
```

## Licenses

MIT. See [LICENSE](LICENSE).

The bundled [Phosphor Icons](https://phosphoricons.com) path data is also MIT.
Its notice is in [licenses/phosphor-LICENSE](licenses/phosphor-LICENSE).
`ConfirmCard.qml` is adapted from the Omarchy shell's ConfirmDialog, MIT,
with its notice in [licenses/omarchy-LICENSE](licenses/omarchy-LICENSE).

Not affiliated with, endorsed by, or connected to Nothing Technology Limited.
"Nothing", "CMF" and the product names are their trademarks, used here only to
say what this controls.
