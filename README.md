# Nothing Buds

ANC, battery and playback controls for Nothing and CMF earbuds, as an Omarchy
bar widget.

<p>
  <img src="preview.png" alt="Panel on a dark theme" width="300">
  <img src="preview-light.png" alt="Panel on a light theme" width="300">
</p>

The panel follows your Omarchy theme; both shots are the same build.

- A dot on the bar icon carries the mode. Filled for ANC, hollow for
  transparency, drained when off or disconnected.
- Noise control: off, transparency, and ANC at low, mid, high or adaptive.
- Per-bud and case battery. The meter turns urgent below 20% and pulses while
  charging.
- Low lag mode and in-ear detection.
- Connect and disconnect the buds from the panel header.
- Find my buds. The tone stops itself after 8 seconds.

Developed against CMF Buds 2 (B179). Other Nothing and CMF models speak the
same protocol, but I have only tested that one. If the panel never connects,
check the [RFCOMM channel](#rfcomm-channel) first.

## Requirements

| | |
|---|---|
| [earctl](https://github.com/DaanHessen/earctl) | Speaks the Nothing RFCOMM protocol. AGPL-3.0. This plugin calls it as a separate program over its local HTTP API and does not bundle it. The source-build path is pinned to the exact commit behind v0.1.2 |
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
anything by itself: the panel opens with a short list of what setup installs
and a "Set up now" button. The click is the consent; the panel then runs
`setup/install.sh --yes`.

What that click installs:

- the `earbuds` wrapper into `~/.local/bin`,
- `earctl.service`, a systemd **user** service that keeps the RFCOMM session
  open,
- a pinned earbuds address in `~/.config/earbuds`,
- earctl itself, if it is not already on the machine.

Nothing runs as root. earctl is the one exception to "no password": if it is
missing, setup stops without touching anything else and the panel offers an
"Install earctl" button that opens a terminal, where the installer prints its
plan and asks `Proceed? [y/N]` before doing anything.

Every file is written atomically (temp file + rename, never through a
symlink), recorded in a manifest at
`~/.local/state/io.github.saiaungminkhant.nothing-buds/`, and backed up before
replacement. A pre-existing file that this plugin cannot prove it owns
(manifest record, or byte-identical to a version this plugin ships or has
shipped) is refused with exit 5 rather than overwritten; `--replace-existing`
overrides that for a human who wants it, keeping the old copy in the
`backup/` directory.

The panel decides whether to offer setup by running `install.sh --check`,
which exits 0 only when the wrapper is present and byte-identical to the one
in the plugin folder, the unit exists, and earctl is found. It changes
nothing and asks nothing.

Installer exit codes: `0` done · `1` (`--check` only) missing or out of date ·
`2` earctl missing, needs a terminal · `3` base dependency missing · `4`
consent not given · `5` pre-existing object refused · `6` operational failure
(everything rolled back).

You can also run the installer directly:

```sh
~/.config/omarchy/plugins/io.github.saiaungminkhant.nothing-buds/setup/install.sh
```

Run by hand it prints its plan and asks before proceeding, and installs earctl
too, since it has a terminal to work with. A failed run rolls back everything
it did, restoring backups.

**Upgrading from before the manifest existed** (version 0.0.1): the panel
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

The uninstall is manifest-driven: it removes exactly the objects recorded at
install time, and only while they are still provably ours — same recorded
hash, not currently a symlink. Files you edited are left alone, directories
are removed only when empty, and an earctl this plugin never installed is
never touched. The manifest itself and the backups go too.

earctl goes the way it came: the AUR package through the package manager
(`yay -Rns`, the one step that may ask for a password), or the built binary
by exact recorded path. Pass `--keep-earctl` if something else on your system
uses it.

Installs made before the manifest existed get the safe subset: only the
wrapper and unit are removed, and only if their content still matches a
version this plugin ships or has shipped. Everything else is listed for manual
cleanup.

## Configuration

The wrapper resolves your earbuds' address in this order: `--address`, then
`~/.config/earbuds/address`, then the first paired device whose name looks
like a Nothing or CMF product. `install.sh` writes the config file for you.
The RFCOMM channel resolves the same way (`--channel`, then
`~/.config/earbuds/channel`, else 16). Values are validated — an address must
match `AA:BB:CC:DD:EE:FF`, a channel must be 1–63 — and anything that fails is
ignored with a note rather than passed to a command.

To pin per-widget instead, add keys to this widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.saiaungminkhant.nothing-buds", "address": "AA:BB:CC:DD:EE:FF", "channel": 16 }
```

The panel validates these too and shows "Ignoring invalid address/channel in
shell.json" if one fails the grammar, instead of building a command with them.
The `EARBUDS_ADDR`, `EARBUDS_CHANNEL` and `EARCTL` environment variables from
the first release are gone: an environment variable is an executable/input
steering mechanism this plugin no longer has.

### RFCOMM channel

earctl finds the channel with `sdptool`. Arch no longer ships it, and it now
lives in AUR `bluez-utils-compat`, so the wrapper pins 16 instead. That is the
right channel for CMF Buds 2.

Other models differ. Probe for the channel that *answers*, not the ones that
merely accept a connection:

```sh
for ch in $(seq 1 30); do
  earctl disconnect >/dev/null 2>&1
  earctl auto-connect --bluetooth-address "$ADDR" --channel "$ch" >/dev/null 2>&1 \
    && earctl battery >/dev/null 2>&1 && echo "channel $ch works"
done
```

On my buds five channels opened and four of them went quiet. Only one returned
a battery reading.

## What is not here

None of these are hardware limits. The Nothing X app drives all four on the
same earbuds. They are gaps in earctl.

| | |
|---|---|
| Equalizer | `eq set` returns ok and the device ignores it. It always reads back mode 0 |
| Ultra bass | Rejected as unsupported. `earctl detect` returns `model_id: null` because B179 is missing from its model table |
| Spatial audio | No protocol opcode in earctl at all |
| Gestures | Readable over `/api/gestures` as raw numeric codes, with no name mapping |

## Security

The marketplace review asked for four things, and this is where each lives:

| Requirement | Mechanism |
|---|---|
| Setup must be an explicit, consented action; no overwriting objects the plugin cannot prove it owns | Setup runs only from the panel's "Set up" click (`--yes`) or a y/N prompt in a terminal. `setup/lib.sh` installs through `nb_install_file`: symlinked targets are refused, pre-existing files are refused unless recorded in the manifest or byte-identical to a version shipped here, replaced files are backed up, and everything is published by atomic rename. The panel only ever probes with `install.sh --check`, which is read-only. `bash setup/test.sh` S1, S6, S7, S9, S15, S16 |
| Uninstall must remove only what this installation created | A manifest at `~/.local/state/io.github.saiaungminkhant.nothing-buds/` records every file, directory and package created. Removal is hash-checked, symlink-checked, empty-dir-only, and never recurses by inference. Legacy installs get content-matching only. S3, S8, S11, S12 |
| Helper calls need deadlines and output caps; a hung or noisy helper must not wedge the panel | Every wrapper call is wrapped in `/usr/bin/timeout` with byte caps on consumed output, and each helper runs in its own process group so a forked grandchild dies with it; the panel wraps every operation in `/usr/bin/timeout --kill-after=5 <deadline>`, streams stdout/stderr through capped parsers, and a watchdog plus supersession rules guarantee `busy`/link state always clears. S13 |
| Executable identity and input boundaries must not be steerable | All binaries are invoked by absolute path; the `EARCTL`/`EARBUDS_ADDR`/`EARBUDS_CHANNEL` overrides are removed; the panel passes overrides as validated arguments; config files are read bounded, without following symlinks, and validated against a Bluetooth-address grammar before use. S14 |

`setup/test.sh` runs all of this against fakes in a throwaway HOME — no root,
no network, no real systemd — and is the evidence for the table above.

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

Not affiliated with, endorsed by, or connected to Nothing Technology Limited.
"Nothing", "CMF" and the product names are their trademarks, used here only to
say what this controls.
