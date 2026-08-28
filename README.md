# idle-ladder

An [Omarchy](https://omarchy.org/) shell plugin that adds the two rungs Omarchy's idle
service does not have: the backlight fades as a warning *before* the idle lock, and the
machine suspends a while *after* it.

Upstream's ladder is two rungs — screensaver and lock — and it treats a laptop on battery
exactly like a desktop on mains. This plugin adds a rung at each end, and every timing can
differ by power source.

```
  fade     lock - fadeLead      the backlight walks down; any activity restores it
  lock     idle.lock            upstream's, unless `lock` moves it earlier for this power source
  suspend  lock + suspendAfter  systemctl suspend
```

## Install

```bash
omarchy plugin add https://github.com/bnrobinson93/omarchy-idle-ladder.git
omarchy plugin enable idle-ladder
```

Updates come from `omarchy plugin update idle-ladder`. The plugin is a service — it adds
nothing to the bar.

It needs `brightnessctl` for the fade rung; Omarchy already installs it.

## Configuration

Settings live on the plugin's own entry in `~/.config/omarchy/shell.json`, the same place
`omarchy.clock` takes its `format` from. Edits hot-reload with the rest of the shell
config. Every key is optional.

```json
{
  "plugins": [
    {
      "id": "idle-ladder",
      "ac": { "fadeLead": 5, "suspendAfter": false },
      "battery": { "fadeLead": 120, "lock": 300, "suspendAfter": 120 }
    }
  ]
}
```

| Key | Default (`ac`) | Default (`battery`) | What it does |
| --- | --- | --- | --- |
| `fadeLead` | `5` | `120` | Seconds before the lock that the backlight starts fading. The fade itself takes about three seconds whatever the lead is, then holds the backlight low until the lock or an activity restore. |
| `lock` | upstream's | upstream's | Seconds of idle before the screen locks, for this power source only. |
| `suspendAfter` | off | `120` | Seconds after the lock before the machine suspends. |

Values are seconds. `false` or `0` switches a rung off; omitting a key leaves the default
in place.

### The `lock` key only moves the lock *earlier*

The lock rung belongs to Omarchy's own idle service, which reads a single `idle.lock` for
both power sources. This plugin can beat that timer to it — locking sooner on battery, say
— but it cannot delay a lock it does not own. A `lock` value at or past `idle.lock` is
ignored, with a warning in the shell log. Set the *later* of your two lock times as
`idle.lock`, and the earlier one here:

```json
{
  "idle": { "screensaver": 300, "lock": 900 },
  "plugins": [
    { "id": "idle-ladder", "battery": { "lock": 300 } }
  ]
}
```

That locks after 15 minutes plugged in and after 5 minutes on battery.

### Suspending on AC

Off by default, since a plugged-in machine usually has a reason to stay up. Turn it on the
same way as anywhere else:

```json
{ "id": "idle-ladder", "ac": { "suspendAfter": 600 } }
```

## What it respects

- **`stay-awake`** — Omarchy's stay-awake indicator disables upstream's whole idle cycle,
  and it stops the fade, the early lock, and the suspend here too.
- **`suspend-off`** — the toggle that hides Suspend from the Omarchy menu also holds this
  plugin's suspend rung back.
- **Idle inhibitors** — every rung is registered with `respectInhibitors`, so a video
  playing full screen keeps the ladder from starting.

## Checking what it is doing

Each rung narrates itself into the shell log next to upstream's idle service:

```bash
journalctl --user -f | grep idle-ladder
```

At startup and on any config or power-source change it logs the whole ladder:

```
idle-ladder: fade at 780s, lock at 900s, suspend off (ac)
idle-ladder: fade at 180s, lock at 300s (ours), suspend at 420s (battery)
```

Editing plugin files in `~/.config/omarchy/plugins/idle-ladder/` needs
`omarchy restart shell` to take effect — the shell logs a reload on save but keeps running
the code it loaded at install time. Config edits in `shell.json` do hot-reload.

## Remove

```bash
omarchy plugin remove idle-ladder
```

That disables the service, drops its entry from `~/.config/omarchy/shell.json`,
and deletes the plugin directory. Nothing is left behind elsewhere: the ladder
keeps no state of its own, and the lock reverts to `idle.lock` for both power
sources. Removing it *during* a fade is the one case worth knowing about: the
fade has no teardown hook, so the backlight stays where it was left. `idle-dim`
saves the old level with `brightnessctl -s`, so `brightnessctl -r` brings it
back.

## License and dependencies

MIT — see [LICENSE](LICENSE).

| Dependency | Required | Why |
| --- | --- | --- |
| Omarchy 4 (Quattro) with Quickshell | yes | the shell that hosts the plugin |
| `brightnessctl` | for the fade rung | walks the backlight down and restores it; Omarchy already installs it |
| `systemctl` | for the suspend rung | `systemctl suspend`, from systemd |

Nothing is vendored, nothing is compiled, and no network call is made.
