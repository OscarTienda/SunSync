# EDID injection — a DE-agnostic virtual display (experimental)

SunSync's main path creates a virtual monitor with `krfb-virtualmonitor` and is
**KDE Plasma Wayland only**. This folder is a different approach for everyone
else: instead of asking the compositor to invent an output at runtime, you
override the EDID of a connector **at boot** so the kernel presents a display at
exactly the resolution you want. That happens *below* the desktop, so the same
trick works on KDE, GNOME and wlroots, and lets you stream a device at its
native resolution (a phone, handheld, laptop, …) by giving that connector
the right modes.

The runtime scripts here don't create anything — they just steer Sunshine onto
that connector while you play and put your real monitors back when you quit.

> **Status:** the EDID setup below is DE-agnostic and the part that matters.
> The runtime display-juggling is **fully implemented and tested on KDE**;
> GNOME (`gdctl`/`gnome-randr`) and wlroots (`wlr-randr`) paths are
> **best-effort and untested** — see [Compositor support](#compositor-support).
> Feedback / PRs from GNOME users very welcome.

---

## Getting it

This lives on a branch, not a release, so it isn't on the AUR — run SunSync from
source:

```bash
git clone https://github.com/OscarTienda/SunSync.git
cd SunSync
git checkout edid-injection
```

See the main README's *Install → From source* for the Python side. If you
already have the released `sunsync` installed, that works too — the only
app-level step is wiring the prep scripts (Step 6); everything else is the
scripts in this folder plus the boot-time EDID setup.

---

## How it compares to the krfb path

| | krfb virtual monitor (main) | EDID injection (this folder) |
|---|---|---|
| Desktop | KDE Plasma only | KDE / GNOME / wlroots |
| Created | at runtime, per stream | once, at boot |
| Resolution | dynamic, matches client | fixed by the EDID you inject |
| Setup | none beyond the wizard | one-time: EDID file + kernel cmdline + reboot |
| Best for | KDE users who want it to "just work" | non-KDE users, or fixed device profiles |

Because the injected output is fixed, you typically prepare **one EDID per
device you stream to**. If you only ever stream from one phone/tablet, you only
need one.

---

## What you need

- A spare connector to carry the injected EDID. Two options:
  - **A dummy plug** (cheap HDMI/DP "headless" adapter) — recommended, most
    reliable: the connector reads as *connected*, you only override its EDID.
  - **A truly headless connector** (nothing plugged in) — also possible but you
    must force-enable it on the kernel cmdline (`video=<conn>:e`), which is
    fussier and GPU-dependent.
- Root access to edit the kernel command line and regenerate the initramfs.
- Sunshine on the same machine, already capturing your desktop.

---

## Step 1 — Find the connector name

Boot normally with the dummy plug inserted (or the connector you'll force on),
then list connectors:

```bash
for p in /sys/class/drm/card*-*/; do
    nm="${p%/}"; nm="${nm##*/card?-}"
    st="$(cat "$p/status" 2>/dev/null)"
    printf '%-12s %s\n' "$nm" "$st"
done
```

You'll get names like `DP-3`, `HDMI-A-2`. Pick the one for your dummy plug /
spare port and note it — call it `<CONN>` from here on. This is the same name
the kernel cmdline and the runtime scripts use.

---

## Step 2 — Get an EDID binary

You need a `.bin` EDID whose preferred mode is your target resolution.

**Easiest — generate one** with
[RobertoNegro/edid-generator](https://github.com/RobertoNegro/edid-generator)
(an interactive CLI built for exactly this — virtual displays / dummy plugs /
remote gaming on Wayland):

```bash
git clone https://github.com/RobertoNegro/edid-generator
cd edid-generator
npm install
npm run generate     # pick interface, resolution(s) + refresh, preferred mode
```

Add every resolution/refresh your client might request (e.g. 1280x800@60 for an
800p handheld) and set the native one as the preferred mode. It writes a `.bin`.

**Alternatives:**
- Reuse a real monitor's EDID: `cp /sys/class/drm/card*-<CONN>/edid mine.bin`.
- Grab a matching panel from [linuxhw/EDID](https://github.com/linuxhw/EDID).

---

## Step 3 — Install the EDID and point the kernel at it

```bash
sudo mkdir -p /usr/lib/firmware/edid
sudo cp your-display.bin /usr/lib/firmware/edid/your-display.bin
```

Add to the kernel command line (path is relative to `/usr/lib/firmware`):

```
drm.edid_firmware=<CONN>:edid/your-display.bin
```

For a **truly headless** connector (no dummy plug) also force it on:

```
drm.edid_firmware=<CONN>:edid/your-display.bin video=<CONN>:e
```

Where the cmdline lives depends on your bootloader:

- **Limine** (CachyOS default): edit the `cmdline:` line in
  `/boot/limine.conf` (or your distro's snippet) and append the parameters.
- **systemd-boot:** add to `options` in `/boot/loader/entries/*.conf`, or to
  `/etc/kernel/cmdline` then run `sudo reinstall-kernels` / `sbctl`.
- **GRUB:** add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

Multiple connectors: comma-separate, e.g.
`drm.edid_firmware=DP-3:edid/client-a.bin,HDMI-A-2:edid/client-b.bin`.

---

## Step 4 — Put the EDID in the initramfs

The firmware must be readable during early KMS, so it has to be in the
initramfs.

**mkinitcpio (Arch / CachyOS):** add the file to the `FILES=()` array in
`/etc/mkinitcpio.conf`:

```
FILES=(/usr/lib/firmware/edid/your-display.bin)
```

then rebuild:

```bash
sudo mkinitcpio -P
```

**dracut:** `install_items+=" /usr/lib/firmware/edid/your-display.bin "` in a
`/etc/dracut.conf.d/*.conf`, then `sudo dracut -f`.

**initramfs-tools (Debian/Ubuntu):** drop a hook that copies the file, then
`sudo update-initramfs -u`.

---

## Step 5 — Reboot and verify

```bash
# the connected dummy now reports your injected modes:
cat /sys/class/drm/card*-<CONN>/modes
# kernel log should mention loading the firmware EDID:
sudo dmesg | grep -i edid
```

You should see your target resolution in the modes list. If not, re-check the
connector name, the cmdline, and that the file made it into the initramfs.

---

## Step 6 — Wire the scripts into SunSync

Copy the runtime scripts somewhere on PATH and make them executable:

```bash
install -Dm755 scripts/edid/sunshine-start-edid.sh ~/.local/bin/sunshine-start-edid.sh
install -Dm755 scripts/edid/sunshine-stop-edid.sh  ~/.local/bin/sunshine-stop-edid.sh
```

Tell SunSync to use them as the external prep-cmd (rides along on every game):

```bash
python sunsync.py display external-prep set \
    --do  ~/.local/bin/sunshine-start-edid.sh \
    --undo ~/.local/bin/sunshine-stop-edid.sh
python sunsync.py display external-prep status   # confirm
```

The scripts need to know which connector carries the injected EDID. They read
`SUNSYNC_EDID_OUTPUT` from the environment and **do nothing if it's unset**
(so a half-configured prep-cmd can never black out your desktop). Set it where
Sunshine can see it — e.g. in Sunshine's own environment, or wrap the script:

```bash
# ~/.local/bin/sunshine-start-edid.sh is generic; export the connector first.
SUNSYNC_EDID_OUTPUT=<CONN> ~/.local/bin/sunshine-start-edid.sh
```

The simplest reliable approach is a two-line wrapper per script that exports
`SUNSYNC_EDID_OUTPUT=<CONN>` and then `exec`s the real script, and point the
prep-cmd at the wrapper.

---

## Step 7 — Sunshine capture

The injected output is now a normal monitor, but Sunshine still has to capture
*it*:

- **KDE:** keep `capture = kwin` (same as the main path).
- **GNOME / wlroots:** `capture = kwin` does **not** apply. Use Sunshine's KMS
  capture and select the injected connector as the output. See the Sunshine
  docs for `capture = kms` and the `output_name` setting. This is the part that
  varies most between setups and is least tested here.

---

## Compositor support

| Compositor | Tool used | Status |
|---|---|---|
| KDE Plasma (KWin) | `kscreen-doctor` + `qdbus6` | **Tested** |
| GNOME 48+ (Mutter) | `gdctl` | Experimental, untested |
| GNOME (older) | `gnome-randr` | Experimental, untested |
| wlroots (Sway, …) | `wlr-randr` | Experimental, untested |

**GNOME restore caveat:** Mutter has no "restore previous layout" call, so the
stop script can only nudge it back onto a physical monitor. If your desktop
doesn't return cleanly after a stream, toggling a display in Settings (or
unplug/replug) forces Mutter to re-apply its saved layout. Improving this is
the obvious next contribution.

---

## Troubleshooting

- **Injected modes don't appear** → connector name wrong, cmdline typo, or the
  `.bin` isn't in the initramfs (Step 4). Check `sudo dmesg | grep -i edid`.
- **Scripts do nothing** → `SUNSYNC_EDID_OUTPUT` not set in Sunshine's env
  (Step 6). The scripts log this to stderr and exit cleanly on purpose.
- **Real monitors don't come back (KDE)** → run the stop script by hand:
  `SUNSYNC_EDID_OUTPUT=<CONN> ~/.local/bin/sunshine-stop-edid.sh`.
- **Wrong resolution while streaming** → the client asked for a mode the EDID
  doesn't list. Add that resolution to the EDID (Step 2) and reinstall.
