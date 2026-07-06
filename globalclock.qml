pragma Singleton
import Quickshell
import QtQuick

Singleton {
    id: root

    SystemClock {
        id: systemClock
        precision: SystemClock.Minutes // optimize updates
    }

    // expose date globally
    readonly property var date: systemClock.date
}

