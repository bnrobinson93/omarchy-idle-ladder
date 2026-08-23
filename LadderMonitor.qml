import QtQuick
import Quickshell.Wayland

// An IdleMonitor registers its timeout with the compositor the moment it is
// created and never re-registers when `timeout` changes afterwards. Every
// timeout here comes from shell.json, which lands *after* startup, so a bare
// monitor would stay armed at whatever the built-in default implied while the
// QML property reads the configured number and lies about it.
//
// Toggling `enabled` forces a fresh registration, and the toggle has to span an
// event loop turn: setting it false and true inside one tick coalesces into no
// change at all, and the stale registration survives. Hence the one-shot timer.
Item {
  id: root

  property int timeout: 0
  // A rung the config switched off, or one whose timeout has not resolved yet.
  property bool active: true

  signal idled()
  signal woke()

  readonly property bool armed: root.active && root.timeout > 0

  onTimeoutChanged: root.rearm()

  function rearm() {
    monitor.enabled = false
    rearmTimer.restart()
  }

  IdleMonitor {
    id: monitor
    enabled: root.armed
    timeout: root.timeout
    respectInhibitors: true
    onIsIdleChanged: isIdle ? root.idled() : root.woke()
  }

  Timer {
    id: rearmTimer
    interval: 1
    // Qt.binding, not a bare `true`: assigning `enabled` above broke the
    // binding to `armed`, and a rung switched off later must still go quiet.
    onTriggered: monitor.enabled = Qt.binding(() => root.armed)
  }
}
