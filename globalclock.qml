pragma Singleton
import Quickshell
import QtQuick

Singleton {
    id: root

    SystemClock {
        id: systemClock
        precision: SystemClock.Minutes // optimize updates to once per minute
    }

    // expose the date object globally
    readonly property var date: systemClock.date
}

