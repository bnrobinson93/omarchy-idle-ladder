import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower

// The rungs Omarchy's idle service does not have: a warning before the screen
// goes, and sleep after it.
//
// Upstream's ladder is exactly two rungs — screensaver and lock — read from
// `idle.screensaver` and `idle.lock`, with no dim step, no step past the lock,
// and no notion of which power source the machine is on. This adds the missing
// ends of the ladder as extra idle monitors beside upstream's:
//
//   fade     lock - fadeLead      `idle-dim` walks the backlight down; activity restores it
//   lock     idle.lock            upstream's, unless `lock` moves it *earlier* for this power source
//   suspend  lock + suspendAfter  `systemctl suspend`
//
// Monitors of our own rather than hooks into upstream's: the idle service
// exposes only status over IPC, and the alternatives (shadowing
// omarchy-brightness-display, which the lock calls *after* the screen is
// already locked, or shadowing omarchy-system-lock, which would delay a manual
// lock too) both fire at the wrong moment.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  // The fade script ships beside this file, so the plugin works wherever
  // `omarchy plugin add` puts it. Process wants a path, not a URL.
  readonly property string dimCommand: Qt.resolvedUrl("idle-dim").toString().replace("file://", "")

  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : ({})
  readonly property int upstreamLockSeconds: Number(idleConfig.lock) > 0 ? Number(idleConfig.lock) : 300

  // ------------------------------------------------------------------ config
  //
  // Settings ride on this plugin's own entry in shell.json's `plugins` array,
  // the way omarchy.clock takes `format` off its bar entry. The registry
  // matches those entries on `id` alone and leaves every other key untouched,
  // so there is no second config file to keep, and edits hot-reload with the
  // rest of the shell config:
  //
  //   { "id": "idle-ladder",
  //     "ac":      { "fadeLead": 5,   "suspendAfter": false },
  //     "battery": { "fadeLead": 120, "lock": 300, "suspendAfter": 120 } }

  readonly property var pluginConfig: root.configFor(shell && shell.shellConfig ? shell.shellConfig : null)
  readonly property var powerConfig: {
    var section = UPower.onBattery ? root.pluginConfig.battery : root.pluginConfig.ac
    return section && typeof section === "object" ? section : ({})
  }

  function configFor(config) {
    var id = manifest && manifest.id ? String(manifest.id) : "idle-ladder"
    var entries = config && Array.isArray(config.plugins) ? config.plugins : []
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && String(entries[i].id) === id) return entries[i]
    return ({})
  }

  // Absent means "use the default"; `false` or `0` means "switch this rung
  // off". Anything else is a positive number of seconds or it is nonsense, and
  // nonsense switches the rung off rather than guessing a timing that puts the
  // machine to sleep.
  function seconds(value, fallback) {
    if (value === null || value === undefined) return fallback
    if (value === false) return 0
    var parsed = Number(value)
    return isFinite(parsed) && parsed > 0 ? Math.round(parsed) : 0
  }

  // On battery the fade starts early, so the panel spends the last couple of
  // minutes dim rather than bright; plugged in it is only the warning before
  // the lock. The machine staying up while plugged in is why the suspend rung
  // is off by default on AC and on by default on battery.
  readonly property int fadeLeadSeconds: root.seconds(root.powerConfig.fadeLead, UPower.onBattery ? 120 : 5)
  readonly property int suspendAfterSeconds: root.seconds(root.powerConfig.suspendAfter, UPower.onBattery ? 120 : 0)

  // `lock` can only pull the lock *earlier* for this power source: a later one
  // would need upstream's own timer to move, and this plugin does not own that
  // rung. An override at or past `idle.lock` is ignored, loudly.
  readonly property int lockOverrideSeconds: root.seconds(root.powerConfig.lock, 0)
  readonly property bool ownsLock: root.lockOverrideSeconds > 0 && root.lockOverrideSeconds < root.upstreamLockSeconds
  readonly property int lockSeconds: root.ownsLock ? root.lockOverrideSeconds : root.upstreamLockSeconds

  readonly property int fadeTimeoutSeconds: Math.max(1, root.lockSeconds - root.fadeLeadSeconds)
  readonly property int suspendTimeoutSeconds: root.lockSeconds + root.suspendAfterSeconds

  // Both flags upstream already honours elsewhere, checked at fire time rather
  // than watched: `stay-awake` disables upstream's whole idle cycle (and
  // `idle-dim` bails on it too), and `suspend-off` is the toggle that hides the
  // menu's own Suspend row.
  readonly property string stayAwakeGuard: "[[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ]] && exit 0"
  readonly property string lockCommand: root.stayAwakeGuard + "; omarchy-system-lock"
  readonly property string suspendCommand: root.stayAwakeGuard + "; omarchy-toggle-enabled suspend-off || systemctl suspend"

  function run(process, command) {
    if (process.running) return
    process.command = command
    process.running = true
  }

  function dim(argument) {
    console.log("idle-ladder: dim " + argument)
    root.run(argument === "fade" ? fadeProcess : restoreProcess, [root.dimCommand, argument])
  }

  LadderMonitor {
    timeout: root.fadeTimeoutSeconds
    onIdled: root.dim("fade")
    onWoke: root.dim("restore")
  }

  // Upstream still locks at `idle.lock`; this rung only gets there first. It
  // runs the same command upstream's lock timer does, so an early lock and an
  // upstream lock are the same lock.
  LadderMonitor {
    active: root.ownsLock
    timeout: root.lockSeconds
    onIdled: {
      console.log("idle-ladder: locking after " + root.lockSeconds + "s idle, ahead of upstream's " + root.upstreamLockSeconds + "s")
      root.run(lockProcess, ["bash", "-lc", root.lockCommand])
    }
  }

  // Windows' pattern: screen off, then sleep a beat later.
  LadderMonitor {
    active: root.suspendAfterSeconds > 0
    timeout: root.suspendTimeoutSeconds
    onIdled: {
      console.log("idle-ladder: suspending after " + root.suspendTimeoutSeconds + "s idle on " + (UPower.onBattery ? "battery" : "ac"))
      root.run(suspendProcess, ["bash", "-lc", root.suspendCommand])
    }
  }

  Process { id: fadeProcess }
  Process { id: restoreProcess }
  Process { id: lockProcess }
  Process { id: suspendProcess }

  // Upstream's idle service narrates itself into the shell log; silent second
  // monitors would be indistinguishable from ones that never loaded. Log the
  // timeouts too, since shell.json lands after startup and the first value a
  // binding sees is the built-in default rather than ours.
  function logTimeouts() {
    console.log("idle-ladder: fade at " + root.fadeTimeoutSeconds + "s, lock at " + root.lockSeconds
      + "s" + (root.ownsLock ? " (ours)" : "") + ", suspend "
      + (root.suspendAfterSeconds > 0 ? "at " + root.suspendTimeoutSeconds + "s" : "off")
      + " (" + (UPower.onBattery ? "battery" : "ac") + ")")

    if (root.lockOverrideSeconds > 0 && !root.ownsLock)
      console.warn("idle-ladder: ignoring lock=" + root.lockOverrideSeconds
        + "s, it is not earlier than idle.lock=" + root.upstreamLockSeconds + "s; this rung can only lock sooner")
  }

  onFadeTimeoutSecondsChanged: root.logTimeouts()
  onLockSecondsChanged: root.logTimeouts()
  onSuspendTimeoutSecondsChanged: root.logTimeouts()
  Component.onCompleted: root.logTimeouts()
}
