import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland

// The rungs v4's idle service does not have: a warning before the screen goes,
// and sleep after it.
//
// Upstream's ladder is exactly two rungs — screensaver and lock — read from
// `idle.screensaver` and `idle.lock`, with no dim step, no third step past the
// lock, and no notion of which power source the machine is on. This adds the
// missing ends of the ladder as extra IdleMonitors beside upstream's:
//
//   fade    lock - lead      `idle-dim` walks the backlight down; activity restores it
//   lock    idle.lock        upstream's, untouched
//   suspend lock + delay     battery only, `systemctl suspend`
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

  // The fade script ships beside this file, so the plugin works wherever
  // `omarchy plugin add` puts it. Process wants a path, not a URL.
  readonly property string dimCommand: Qt.resolvedUrl("idle-dim").toString().replace("file://", "")
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : ({})
  readonly property int lockSeconds: Number(idleConfig.lock) > 0 ? Number(idleConfig.lock) : 300

  // The fade itself takes about three seconds whatever the lead is, then holds
  // the backlight low until the lock or an activity restore. On battery it
  // starts early so the panel spends the last couple of minutes dim rather than
  // bright; plugged in it is only the warning it has always been.
  readonly property int leadSecondsOnAc: 5
  readonly property int leadSecondsOnBattery: 120
  readonly property int leadSeconds: UPower.onBattery ? root.leadSecondsOnBattery : root.leadSecondsOnAc
  readonly property int fadeTimeoutSeconds: Math.max(1, root.lockSeconds - root.leadSeconds)

  // Windows' pattern: screen off, then sleep a beat later. Plugged in the
  // machine stays up, so this rung is armed on battery only.
  readonly property int suspendAfterLockSeconds: 120
  readonly property int suspendTimeoutSeconds: root.lockSeconds + root.suspendAfterLockSeconds

  // Both flags upstream already honours elsewhere, checked at fire time rather
  // than watched: `stay-awake` disables upstream's whole idle cycle (and
  // `idle-dim` bails on it too), and `suspend-off` is the toggle that hides the
  // menu's own Suspend row.
  readonly property string suspendCommand: "[[ -f \"$HOME/.local/state/omarchy/indicators/stay-awake\" ]] || omarchy-toggle-enabled suspend-off || systemctl suspend"

  function run(process, command) {
    if (process.running) return
    process.command = command
    process.running = true
  }

  function dim(process, argument) {
    console.log("idle-ladder: dim " + argument)
    root.run(process, [root.dimCommand, argument])
  }

  // An IdleMonitor registers its timeout with the compositor when it is created
  // and does not re-register when `timeout` changes afterwards. Our timeouts are
  // bound to `idle.lock`, and the user config lands *after* startup, so a monitor
  // left alone stays armed at whatever upstream's built-in default implied — 295s
  // here — while the QML property reads the right number and lies about it. The
  // `enabled` toggle below forces a fresh registration; the suspend monitor gets
  // one for free, because `UPower.onBattery` settles after startup too.
  IdleMonitor {
    id: fadeMonitor
    timeout: root.fadeTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: isIdle ? root.dim(fadeProcess, "fade") : root.dim(restoreProcess, "restore")
  }

  // The toggle has to span an event loop turn: setting `enabled` false and true
  // inside one tick coalesces into no change at all, and the stale registration
  // survives.
  function rearmFade() {
    fadeMonitor.enabled = false
    rearmTimer.restart()
  }

  Timer {
    id: rearmTimer
    interval: 1
    onTriggered: {
      fadeMonitor.enabled = true
      console.log("idle-ladder: fade monitor re-armed at " + fadeMonitor.timeout + "s")
    }
  }

  IdleMonitor {
    enabled: UPower.onBattery
    timeout: root.suspendTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: {
      if (!isIdle) return
      console.log("idle-ladder: suspending after " + root.suspendTimeoutSeconds + "s idle on battery")
      root.run(suspendProcess, ["bash", "-lc", root.suspendCommand])
    }
  }

  Process { id: fadeProcess }
  Process { id: restoreProcess }
  Process { id: suspendProcess }

  // Upstream's idle service narrates itself into the shell log; silent second
  // monitors would be indistinguishable from ones that never loaded. Log the
  // timeouts too, since shell.json lands after startup and the first value a
  // binding sees is the built-in default rather than ours.
  function logTimeouts() {
    console.log("idle-ladder: fade at " + root.fadeTimeoutSeconds + "s, lock at " + root.lockSeconds
      + "s, suspend at " + root.suspendTimeoutSeconds + "s (" + (UPower.onBattery ? "battery" : "ac") + ")")
  }

  onFadeTimeoutSecondsChanged: {
    root.rearmFade()
    root.logTimeouts()
  }
  onSuspendTimeoutSecondsChanged: root.logTimeouts()
  Component.onCompleted: root.logTimeouts()
}
