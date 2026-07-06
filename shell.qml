// @ pragma icontheme adwaita
import Quickshell
import QtQuick
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.Notifications
import Quickshell.Widgets

PanelWindow {
    id: window
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: launcherOpen ? 600 : ((editorOpen && popupOpen) ? 400 : 70)
    exclusiveZone: 45 
    color: "transparent"
    WlrLayershell.keyboardFocus: ((editorOpen && popupOpen) || window.selectedSsid !== "" || launcherOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // sleep detection automatically restarts quickshell on wake
    Timer {
        interval: 1000
        running: true
        repeat: true
        property var lastTick: new Date().getTime()
        onTriggered: {
            var now = new Date().getTime();
            if (now - lastTick > 4000) {
                // time jumped by four seconds likely woke up from sleep
                Qt.quit();
            }
            lastTick = now;
        }
    }
    property bool launcherOpen: false
    property var filteredApps: DesktopEntries.applications.values

    IpcHandler {
        target: "launcher"
        function toggle() {
            launcherOpen = !launcherOpen;
            if (launcherOpen) {
                launcherPopup.launcherPowerMenuOpen = false;
                filteredApps = DesktopEntries.applications.values;
                launcherFocusTimer.start();
            }
        }
    }

    Timer {
        id: launcherFocusTimer
        interval: 50
        onTriggered: {
            launcherSearchInput.text = "";
            launcherSearchInput.forceActiveFocus();
        }
    }

    TextInput {
        id: proxyPasswordInput
        visible: window.selectedSsid !== ""
        focus: visible
        opacity: 0
        text: ""
        onVisibleChanged: { if (visible) forceActiveFocus(); }
        onAccepted: {
            if (window.selectedSsid !== "") {
                wifiConnectProc.connectTo(window.selectedSsid, text);
                text = "";
                window.selectedSsid = "";
            }
        }
    }

    FontLoader { id: helveticaFont; source: "Helvetica.ttc" }
    FontLoader { id: materialFont; source: "MaterialIcons-Regular.ttf" }

    // ── nightlight ──
    property bool nightLightEnabled: false

    // ── osd ──
    property real currentVolume: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0
    property bool osdVisible: false
    property string osdIcon: "volume_up"
    property real osdValue: 0
    property string osdText: "volume"

    onCurrentVolumeChanged: {
        let isMuted = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.muted : false;
        if (isMuted || currentVolume === 0) osdIcon = "volume_off";
        else if (currentVolume < 0.33) osdIcon = "volume_mute";
        else if (currentVolume < 0.66) osdIcon = "volume_down";
        else osdIcon = "volume_up";
        
        osdValue = currentVolume;
        osdText = Math.round(currentVolume * 100) + "%";
        osdVisible = true;
        osdTimer.restart();
    }

    Timer {
        id: osdTimer
        interval: 2000
        onTriggered: osdVisible = false
    }

    property real currentBrightness: 0
    Process {
        id: brightnessProc
        command: ["sh", "-c", "brightnessctl -m | awk -F, '{print $4}' | tr -d '%'"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                let val = parseInt(data);
                if (!isNaN(val)) {
                    let newBr = val / 100.0;
                    if (currentBrightness !== 0 && currentBrightness !== newBr) {
                        osdIcon = "brightness_7";
                        osdValue = newBr;
                        osdText = Math.round(newBr * 100) + "%";
                        osdVisible = true;
                        osdTimer.restart();
                    }
                    currentBrightness = newBr;
                }
            }
        }
    }
    Timer {
        interval: 250; running: true; repeat: true
        onTriggered: brightnessProc.running = true
    }
    property bool popupOpen: false
    property string selectedDateString: ""
    property real clickedDayY: 100
    property bool editorOpen: false
    property var reminders: ({})
    property var dismissedNotifications: ({})
    property bool notificationsPopupOpen: false
    property bool isNotificationsHovered: (bellMouseArea ? bellMouseArea.containsMouse : false) || (allNotificationsPopup && allNotificationsPopup.visible && notificationsHover ? notificationsHover.hovered : false)
    property bool isRecording: false

    onIsNotificationsHoveredChanged: {
        if (isNotificationsHovered) {
            notificationsCloseTimer.stop();
            notificationsPopupOpen = true;
            popupOpen = false;
            editorOpen = false;
        } else {
            notificationsCloseTimer.start();
        }
    }

    Timer {
        id: notificationsCloseTimer
        interval: 300
        onTriggered: {
            notificationsPopupOpen = false;
        }
    }
    
    NotificationServer {
        id: notificationServer
    }
    
    property var activeNotifications: []
    property int notificationCount: activeNotifications ? activeNotifications.length : 0
    
    property int activeReminderCount: {
        var count = 0;
        for (var key in reminders) {
            if (reminders[key] && reminders[key].trim() !== "") {
                if (key !== todayDateString || !dismissedNotifications[todayDateString]) {
                    count++;
                }
            }
        }
        return count;
    }

    function getRemindersList() {
        var list = [];
        for (var key in reminders) {
            if (reminders[key] && reminders[key].trim() !== "") {
                list.push({ date: key, description: reminders[key] });
            }
        }
        list.sort(function(a, b) {
            return a.date.localeCompare(b.date);
        });
        return list;
    }

    property string todayDateString: {
        var today = GlobalClock.date;
        var year = today.getFullYear();
        var month = today.getMonth();
        var day = today.getDate();
        return year + "-" + 
               ((month + 1) < 10 ? "0" : "") + (month + 1) + "-" + 
               (day < 10 ? "0" : "") + day;
    }

    property string todayReminderText: reminders[todayDateString] || ""
    property bool notificationActive: todayReminderText !== "" && !dismissedNotifications[todayDateString]
    

    
    property var currentSystemNotification: null
    property bool isSystemNotificationActive: currentSystemNotification !== null
    
    Connections {
        target: notificationServer
        function onNotification(notif) {
            notif.tracked = true;
            
            var iconString = notif.appIcon ? notif.appIcon : (notif.image ? notif.image : "");
            if (!iconString && notif.desktopEntry) {
                iconString = notif.desktopEntry;
            }
            if (!iconString && notif.appName) {
                iconString = notif.appName.toLowerCase().replace(/ /g, "-");
            }
            if (iconString && !iconString.startsWith("file:// ") && !iconstring.startswith(" ") && !iconstring.startswith("image: ") && !iconstring.startswith("http")) {
                iconString = "image:// icon " + iconstring;
            }

            var newNotif = {
                appName: notif.appName ? notif.appName : "",
                appIcon: iconString,
                image: notif.image ? notif.image : "",
                summary: notif.summary ? notif.summary : "",
                body: notif.body ? notif.body : "",
                id: notif.id
            };
            
            var copy = activeNotifications.slice();
            var found = false;
            for (var i = 0; i < copy.length; i++) {
                if (copy[i].id === notif.id) {
                    copy[i] = newNotif;
                    found = true;
                    break;
                }
            }
            if (!found) {
                copy.unshift(newNotif);
            }
            activeNotifications = copy;
            
            var isNotifySend = notif.appName === "notify-send";
            currentSystemNotification = { 
                title: isNotifySend ? (notif.summary ? notif.summary : "notification") : (notif.appName ? notif.appName : "notification"), 
                body: isNotifySend ? (notif.body ? notif.body : "") : (notif.summary ? (notif.summary + (notif.body ? "\n" + notif.body : "")) : notif.body),
                icon: iconString
            };
            systemNotifTimer.restart();
        }
    }
    
    Timer {
        id: systemNotifTimer
        interval: 5000
        onTriggered: currentSystemNotification = null
    }

    property bool isCalendarHovered: (timeMouseArea ? timeMouseArea.containsMouse : false) || (calendarHover ? calendarHover.hovered : false) || (editorContainer && editorContainer.visible && editorHover ? editorHover.hovered : false) || (editorContainer && editorContainer.visible && descriptionInput ? descriptionInput.activeFocus : false)

    function toggleCalendarPopup() {
        if (popupOpen) {
            popupOpen = false;
            editorOpen = false;
        } else {
            popupOpen = true;
            notificationsPopupOpen = false;
        }
    }

    onIsCalendarHoveredChanged: {
        // hover auto open disabled
    }

    Timer {
        id: closeTimer
        interval: 300
        onTriggered: {
            popupOpen = false;
            editorOpen = false;
        }
    }

    FileView {
        id: remindersFile
        path: Qt.resolvedUrl("reminders.json").toString().replace("file:// ", "")
        
        onTextChanged: {
            try {
                if (text && text.trim() !== "") {
                    var parsed = JSON.parse(text);
                    if (JSON.stringify(parsed) !== JSON.stringify(reminders)) {
                        reminders = parsed;
                    }
                }
            } catch (e) {
                // ignore parse err
            }
        }
    }

    function saveReminder(dateStr, textStr) {
        var copy = Object.assign({}, reminders);
        if (textStr.trim() === "") {
            delete copy[dateStr];
        } else {
            copy[dateStr] = textStr.trim();
        }
        reminders = copy;
        remindersFile.setText(JSON.stringify(copy, null, 2));
    }

    function formatSelectedDate(dateStr) {
        if (!dateStr) return "";
        var parts = dateStr.split("-");
        var year = parts[0];
        var monthIndex = parseInt(parts[1]) - 1;
        var day = parseInt(parts[2]);
        var monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
        return monthNames[monthIndex] + " " + day + ", " + year;
    }

    function getDateString(dayStr) {
        if (!dayStr) return "";
        var year = GlobalClock.date.getFullYear();
        var month = GlobalClock.date.getMonth();
        var day = parseInt(dayStr);
        return year + "-" + 
               ((month + 1) < 10 ? "0" : "") + (month + 1) + "-" + 
               (day < 10 ? "0" : "") + day;
    }

    property int activeWorkspace: 1
    property int startWorkspace: 1
    property var tagData: []

    Process {
        id: mangoIpc
        command: ["mmsg", "watch", "all-monitors"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var parsed = JSON.parse(data);
                    var monitor = parsed.monitors[0];
                    if (monitor) {
                        if (monitor.active_tags && monitor.active_tags.length > 0) {
                            var active = monitor.active_tags[0];
                            if (active !== activeWorkspace) {
                                activeWorkspace = active;
                                updateStartWorkspace(active);
                            }
                        }
                        if (monitor.tags) {
                            tagData = monitor.tags;
                        }
                    }
                } catch (e) {
                    // ignore parse err
                }
            }
        }
    }

    Process {
        id: switcher
        running: false
        function view(ws) {
            command = ["mmsg", "dispatch", "view," + ws + ",0"];
            running = true;
        }
    }

    function getWifiIcon(signal, isSecure) {
        if (isSecure) {
            if (signal >= 80) return "network_wifi_locked";
            if (signal >= 60) return "network_wifi_3_bar_locked";
            if (signal >= 40) return "network_wifi_2_bar_locked";
            if (signal >= 20) return "network_wifi_1_bar_locked";
            return "signal_wifi_0_bar";
        } else {
            if (signal >= 80) return "network_wifi";
            if (signal >= 60) return "network_wifi_3_bar";
            if (signal >= 40) return "network_wifi_2_bar";
            if (signal >= 20) return "network_wifi_1_bar";
            return "signal_wifi_0_bar";
        }
    }

    property string wifiSSID: "disconnected"
    property int wifiSignal: 0
    property bool wifiConnected: false
    property var wifiList: []
    property string selectedSsid: ""
    
    property bool isBluetoothOn: false
    property string connectedBluetoothDevice: ""
    property var bluetoothList: []
    property bool bluetoothListPopupOpen: false
    property bool isBluetoothScanning: false


    property var audioSinkList: []
    property bool audioListPopupOpen: false

    Process {
        id: audioSinkProcess
        command: ["python3", Qt.resolvedUrl("get_sinks.py").toString().replace("file:// ", "")]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var sinks = JSON.parse(data);
                    if (sinks.length > 0) {
                        audioSinkList = sinks;
                    }
                } catch (e) {
                }
            }
        }
    }

    property int batteryPercent: 0
    property bool batteryCharging: false

    function getBatteryIcon(percent, charging) {
        if (charging) {
            return "battery_charging_full";
        } else {
            if (percent >= 75) return "battery_full";
            if (percent >= 50) return "battery_4_bar";
            if (percent >= 25) return "battery_2_bar";
            return "battery_alert";
        }
    }

    property bool wifiPopupOpen: false
    property bool wifiListPopupOpen: false

    function toggleWifiPopup() {
        if (wifiPopupOpen) {
            wifiPopupOpen = false;
            wifiListPopupOpen = false;
            bluetoothListPopupOpen = false;
        } else {
            mediaPopupOpen = false;
            wifiPopupOpen = true;
        }
    }

    property bool mediaPopupOpen: false
    property real mediaPosition: 0
    property bool mediaSliderDragging: false

    function toggleMediaPopup() {
        if (mediaPopupOpen) {
            mediaPopupOpen = false;
        } else {
            wifiPopupOpen = false;
            wifiListPopupOpen = false;
            bluetoothListPopupOpen = false;
            mediaPopupOpen = true;
        }
    }

    // update media position every second during playback
    Timer {
        id: mediaPositionTimer
        interval: 1000
        repeat: true
        running: mediaPlayer.activePlayer !== null && mediaPlayer.activePlayer.isPlaying && !mediaSliderDragging
        onTriggered: {
            if (mediaPlayer.activePlayer) {
                mediaPlayer.activePlayer.positionChanged();
                mediaPosition = mediaPlayer.activePlayer.position;
            }
        }
    }

    function formatTime(seconds) {
        if (isNaN(seconds) || seconds < 0) return "0:00";
        var totalSec = Math.floor(seconds);
        var hrs = Math.floor(totalSec / 3600);
        var mins = Math.floor((totalSec % 3600) / 60);
        var secs = totalSec % 60;
        if (hrs > 0) {
            return hrs + ":" + (mins < 10 ? "0" : "") + mins + ":" + (secs < 10 ? "0" : "") + secs;
        }
        return mins + ":" + (secs < 10 ? "0" : "") + secs;
    }

    Process {
        id: wifiProc
        command: ["bash", "-c", "nmcli -t -f active,ssid,signal,security dev wifi"]
        running: false
        
        property var lines: []
        
        stdout: SplitParser {
            onRead: data => {
                wifiProc.lines.push(data.trim());
            }
        }

        onExited: (exitCode, exitStatus) => {
            var tempConnected = false;
            var tempSSID = "disconnected";
            var tempSignal = 0;
            var otherNets = [];
            var seenSSIDs = {};

            for (var i = 0; i < wifiProc.lines.length; i++) {
                var line = wifiProc.lines[i];
                if (!line) continue;
                var parts = line.split(":");
                if (parts.length < 3) continue;
                var active = parts[0];
                var ssid = parts[1];
                var signal = parseInt(parts[2]) || 0;
                var isSecure = parts.length >= 4 && parts[3].trim() !== "";

                if (!ssid) continue;

                if (active === "yes") {
                    tempConnected = true;
                    tempSSID = ssid;
                    tempSignal = signal;
                    seenSSIDs[ssid] = true;
                } else {
                    if (seenSSIDs[ssid] === undefined || signal > seenSSIDs[ssid]) {
                        seenSSIDs[ssid] = signal;
                        var found = false;
                        for (var j = 0; j < otherNets.length; j++) {
                            if (otherNets[j].ssid === ssid) {
                                otherNets[j].signal = signal;
                                otherNets[j].isSecure = isSecure;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            otherNets.push({ "ssid": ssid, "signal": signal, "issecure": isSecure });
                        }
                    }
                }
            }

            otherNets.sort(function(a, b) { return b.signal - a.signal; });

            wifiConnected = tempConnected;
            wifiSSID = tempSSID;
            wifiSignal = tempSignal;
            wifiList = otherNets;

            wifiProc.lines = [];
        }
    }

    Process {
        id: wifiConnectProc
        running: false
        function connectTo(ssid, password) {
            if (password && password.trim() !== "") {
                command = ["nmcli", "dev", "wifi", "connect", ssid, "password", password];
            } else {
                command = ["nmcli", "dev", "wifi", "connect", ssid];
            }
            running = true;
        }
        onExited: (exitCode, exitStatus) => {
            wifiProc.running = true;
        }
    }

    Timer {
        id: wifiTimer
        interval: 4000 
        running: true
        repeat: true
        onTriggered: {
            if (!wifiProc.running) {
                wifiProc.running = true;
            }
            if (!batteryProc.running) {
                batteryProc.running = true;
            }
            if (!bluetoothStatusProc.running) {
                bluetoothStatusProc.running = true;
            }
        }
    }

    Process {
        id: batteryProc
        command: ["bash", "-c", "bat=$(ls /sys/class/power_supply | grep -i '^bat' | head -n 1); if [ -n \"$bat\" ]; then cat /sys/class/power_supply/$bat/capacity; cat /sys/class/power_supply/$bat/status; else echo '100'; echo 'full'; fi"]
        running: false

        property var lines: []

        stdout: SplitParser {
            onRead: data => {
                batteryProc.lines.push(data.trim());
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (batteryProc.lines.length >= 2) {
                batteryPercent = parseInt(batteryProc.lines[0]) || 0;
                var status = batteryProc.lines[1].toLowerCase();
                batteryCharging = (status === "charging" || status === "full");
            }
            batteryProc.lines = [];
        }
    }

    Process {
        id: bluetoothStatusProc
        command: ["bash", "-c", "if bluetoothctl show | grep -iq 'powered: yes'; then echo 'power:on'; else echo 'power:off'; fi; bluetoothctl devices | while read -r _ mac name; do info=$(bluetoothctl info \"$mac\"); if echo \"$info\" | grep -iq 'connected: yes'; then echo \"device:connected:$mac:$name\"; elif echo \"$info\" | grep -iq 'paired: yes'; then echo \"device:paired:$mac:$name\"; else echo \"device:discover:$mac:$name\"; fi; done"]
        running: false
        
        property var lines: []
        
        stdout: SplitParser {
            onRead: data => {
                bluetoothStatusProc.lines.push(data.trim());
            }
        }
        
        onExited: (exitCode) => {
            if (exitCode === 0) {
                var newList = [];
                var foundConnected = "";
                var isPowerOn = false;
                
                for (var i = 0; i < bluetoothStatusProc.lines.length; i++) {
                    var line = bluetoothStatusProc.lines[i];
                    if (!line) continue;
                    if (line.startsWith("power:")) {
                        isPowerOn = (line.substring(6) === "on");
                    } else if (line.startsWith("device:")) {
                        var parts = line.substring(7).split(":");
                        if (parts.length >= 8) {
                            var status = parts[0];
                            var mac = parts[1] + ":" + parts[2] + ":" + parts[3] + ":" + parts[4] + ":" + parts[5] + ":" + parts[6];
                            var name = parts.slice(7).join(":");
                            
                            newList.push({
                                "mac": mac,
                                "name": name,
                                "status": status
                            });
                            
                            if (status === "connected") {
                                foundConnected = name;
                            }
                        }
                    }
                }
                
                bluetoothList = newList;
                isBluetoothOn = isPowerOn;
                connectedBluetoothDevice = foundConnected;
            }
            bluetoothStatusProc.lines = [];
        }
    }

    Timer {
        id: bluetoothTimer
        interval: 6000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            bluetoothStatusProc.running = true;
        }
    }

    Process {
        id: bluetoothScanProc
        command: ["bluetoothctl", "--timeout", "10", "scan", "on"]
        running: false
        onExited: {
            isBluetoothScanning = false;
            bluetoothStatusProc.running = true;
        }
    }

    Timer {
        id: bluetoothScanTimer
        interval: 10000
        running: false
        repeat: false
        onTriggered: {
            bluetoothScanProc.kill();
            isBluetoothScanning = false;
        }
    }

    Process {
        id: bluetoothCmdProc
        running: false
        
        function togglePower(on) {
            command = ["bluetoothctl", "power", on ? "on" : "off"];
            running = true;
        }
        
        function connectDevice(mac) {
            command = ["bash", "-c", "bluetoothctl pair " + mac + " && bluetoothctl trust " + mac + " && bluetoothctl connect " + mac];
            running = true;
        }
        
        function disconnectDevice(mac) {
            command = ["bluetoothctl", "disconnect", mac];
            running = true;
        }

        function removeDevice(mac) {
            command = ["bluetoothctl", "remove", mac];
            running = true;
        }
        
        function scanDevices() {
            isBluetoothScanning = true;
            bluetoothScanProc.running = true;
            bluetoothScanTimer.restart();
        }
        
        function stopScan() {
            bluetoothScanProc.kill();
            isBluetoothScanning = false;
        }
        
        onExited: (exitCode) => {
            bluetoothStatusProc.running = true;
        }
    }

    Component.onCompleted: {
        wifiProc.running = true;
        batteryProc.running = true;
    }

    function updateStartWorkspace(active) {
        if (active > startWorkspace + 5) {
            startWorkspace = active - 5;
        } else if (active < startWorkspace) {
            startWorkspace = active;
        } else if (active <= startWorkspace + 3) {
            startWorkspace = Math.max(1, startWorkspace - 1);
        }
    }

    function getTagInfo(index) {
        if (!tagData) return null;
        for (var j = 0; j < tagData.length; j++) {
            if (tagData[j].index === index) {
                return tagData[j];
            }
        }
        return null;
    }

    function getDaysForMonth(date) {
        var year = date.getFullYear();
        var month = date.getMonth();
        var firstDay = new Date(year, month, 1).getDay();
        var daysInMonth = new Date(year, month + 1, 0).getDate();
        
        var days = [];
        for (var i = 0; i < firstDay; i++) {
            days.push("");
        }
        for (var day = 1; day <= daysInMonth; day++) {
            days.push(day.toString());
        }
        while (days.length < 42) {
            days.push("");
        }
        return days;
    }

    Canvas {
        id: barCanvas
        property string watchBg: Settings.backgroundColor
        property string watchBd: Settings.borderColor
        onWatchBgChanged: requestPaint()
        onWatchBdChanged: requestPaint()
        
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
        }
        height: 70

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();

            var w = width;
            var h = height;

            ctx.beginPath();
            ctx.moveTo(0, 0); 
            ctx.lineTo(w, 0); 
            ctx.lineTo(w, h); 
            ctx.quadraticCurveTo(w - 8, 40, w - 36, 40);
            ctx.lineTo(36, 40); 
            ctx.quadraticCurveTo(8, 40, 0, h);
            ctx.closePath();

            ctx.fillStyle = Settings.backgroundColor; 
            ctx.fill();

            ctx.beginPath();
            ctx.moveTo(w, h);
            ctx.quadraticCurveTo(w - 8, 40, w - 36, 40);
            ctx.lineTo(36, 40);
            ctx.quadraticCurveTo(8, 40, 0, h);

            ctx.strokeStyle = Settings.borderColor; 
            ctx.lineWidth = 1;
            ctx.stroke();
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Rectangle {
        id: mediaPlayer
        anchors.right: workspaceRow.left
        anchors.rightMargin: 16
        anchors.top: parent.top
        anchors.topMargin: 6
        height: 28
        width: mediaRow.width + 24
        radius: height / 2
        color: (mediaPopupOpen || mediaMouseArea.containsMouse) ? Settings.hoverColor : Settings.hoverLight
        scale: (mediaPopupOpen || mediaMouseArea.containsMouse) ? 1.05 : 1.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        
        property int currentPlayerIndex: 0
        property var activePlayer: Mpris.players.values.length > 0 ? Mpris.players.values[Math.min(currentPlayerIndex, Mpris.players.values.length - 1)] : null
        visible: activePlayer !== null

        MouseArea {
            id: mediaMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggleMediaPopup()
        }

        Row {
            id: mediaRow
            anchors.centerIn: parent
            spacing: 8
            
            Text {
                font.family: materialFont.name
                font.pixelSize: 26
                text: "skip_previous"
                color: prevMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: prevMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (mediaPlayer.activePlayer) {
                            mediaPlayer.activePlayer.previous();
                        }
                    }
                }
            }

            Text {
                font.family: materialFont.name
                font.pixelSize: 26
                text: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.isPlaying ? "pause" : "play_arrow") : "music_note"
                color: playMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: playMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (mediaPlayer.activePlayer) {
                            mediaPlayer.activePlayer.togglePlaying();
                        }
                    }
                }
            }

            Text {
                font.family: materialFont.name
                font.pixelSize: 26
                text: "skip_next"
                color: nextMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 150 } }
                
                MouseArea {
                    id: nextMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (mediaPlayer.activePlayer) {
                            mediaPlayer.activePlayer.next();
                        }
                    }
                }
            }



            Text {
                id: trackText
                font.family: helveticaFont.name
                font.pixelSize: 18
                text: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.trackTitle + (mediaPlayer.activePlayer.trackArtist ? " - " + mediaPlayer.activePlayer.trackArtist : "")) : ""
                color: Settings.textPrimary
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 250) 
                clip: true
            }
        }

    }

    PopupWindow {
        id: mediaHoverPopup
        anchor.window: window

        implicitWidth: 320
        implicitHeight: 200

        anchor.rect.x: Math.min(window.width - width - 10, mediaPlayer.x + mediaPlayer.width / 2 - width / 2)
        anchor.rect.y: 45

        visible: mediaPopupOpen || mediaPopupRect.opacity > 0.01
        color: "transparent"

        HoverHandler {
            id: mediaPopupHover
        }

        Rectangle {
            id: mediaPopupRect
            anchors.fill: parent
            color: Settings.backgroundColor
            radius: 16
            border.color: Settings.borderColor
            border.width: 1

            opacity: mediaPopupOpen ? 1.0 : 0.0
            scale: mediaPopupOpen ? 1.0 : 0.95

            transform: Translate {
                y: (1.0 - mediaPopupRect.scale) * -100
            }

            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            Row {
                id: playerDotsRow
                anchors.top: parent.top
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                visible: Mpris.players.values.length > 1

                Repeater {
                    model: Mpris.players.values.length
                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: index === mediaPlayer.currentPlayerIndex ? Settings.accentColor : Settings.borderColor
                        
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -8
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                mediaPlayer.currentPlayerIndex = index;
                            }
                        }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }
            }

            Rectangle {
                id: albumArtContainer
                anchors.left: parent.left
                anchors.top: playerDotsRow.visible ? playerDotsRow.bottom : parent.top
                anchors.margins: 12
                width: 80
                height: 80
                radius: 10
                color: Settings.surfaceColor
                clip: true

                Image {
                    id: albumArtImage
                    anchors.fill: parent
                    source: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.trackArtUrl || "") : ""
                    fillMode: Image.PreserveAspectCrop
                    visible: status === Image.Ready
                }

                // fallback icon when no art
                Text {
                    anchors.centerIn: parent
                    text: "music_note"
                    font.family: materialFont.name
                    font.pixelSize: 36
                    color: Settings.textSecondary
                    visible: albumArtImage.status !== Image.Ready
                }
            }

            // track title full no elide initially
            Text {
                id: popupTrackTitle
                anchors.left: albumArtContainer.right
                anchors.leftMargin: 12
                anchors.top: albumArtContainer.top
                anchors.topMargin: 4
                anchors.right: parent.right
                anchors.rightMargin: 12
                text: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.trackTitle || "no track") : "no player"
                font.family: helveticaFont.name
                font.pixelSize: 14
                font.bold: true
                color: Settings.textPrimary
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
            }

            Text {
                id: popupTrackArtist
                anchors.left: albumArtContainer.right
                anchors.leftMargin: 12
                anchors.top: popupTrackTitle.bottom
                anchors.topMargin: 4
                anchors.right: parent.right
                anchors.rightMargin: 12
                text: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.trackArtist || "") : ""
                font.family: helveticaFont.name
                font.pixelSize: 12
                color: Settings.textSecondary
                elide: Text.ElideRight
            }

            Row {
                id: popupControls
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: progressRow.top
                anchors.bottomMargin: 4
                spacing: 20

                Text {
                    text: "skip_previous"
                    font.family: materialFont.name
                    font.pixelSize: 28
                    color: popupPrevMouse.containsMouse ? Settings.accentColor : Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: 150 } }

                    MouseArea {
                        id: popupPrevMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (mediaPlayer.activePlayer) mediaPlayer.activePlayer.previous();
                        }
                    }
                }

                Rectangle {
                    width: 40
                    height: 40
                    radius: 20
                    color: popupPlayMouse.containsMouse ? Settings.accentColor : Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: mediaPlayer.activePlayer ? (mediaPlayer.activePlayer.isPlaying ? "pause" : "play_arrow") : "play_arrow"
                        font.family: materialFont.name
                        font.pixelSize: 24
                        color: Settings.backgroundColor
                    }

                    MouseArea {
                        id: popupPlayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (mediaPlayer.activePlayer) mediaPlayer.activePlayer.togglePlaying();
                        }
                    }
                }

                Text {
                    text: "skip_next"
                    font.family: materialFont.name
                    font.pixelSize: 28
                    color: popupNextMouse.containsMouse ? Settings.accentColor : Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: 150 } }

                    MouseArea {
                        id: popupNextMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (mediaPlayer.activePlayer) mediaPlayer.activePlayer.next();
                        }
                    }
                }

                Row {
                    id: popupVisualizerRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    visible: mediaPlayer.activePlayer !== null && mediaPlayer.activePlayer.isPlaying

                    Repeater {
                        model: 4
                        Rectangle {
                            width: 4
                            height: 4
                            radius: 2
                            color: Settings.accentColor
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on height { NumberAnimation { duration: 150 } }
                            Timer {
                                interval: 150 + (index * 50)
                                running: popupVisualizerRow.visible
                                repeat: true
                                onTriggered: {
                                    parent.height = 4 + Math.random() * 12
                                }
                            }
                        }
                    }
                }
            }

            // progress bar and time labels
            Row {
                id: progressRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                anchors.bottomMargin: 14
                spacing: 8

                Text {
                    id: currentTimeText
                    text: formatTime(mediaPlayer.activePlayer ? mediaPlayer.activePlayer.position : 0)
                    font.family: helveticaFont.name
                    font.pixelSize: 11
                    color: Settings.textSecondary
                    anchors.verticalCenter: parent.verticalCenter
                    width: 36
                    horizontalAlignment: Text.AlignRight
                }

                Rectangle {
                    id: sliderTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: progressRow.width - currentTimeText.width - totalTimeText.width - 24
                    height: 4
                    radius: 2
                    color: Settings.borderColor

                    property real trackLength: mediaPlayer.activePlayer ? mediaPlayer.activePlayer.length : 0
                    property real trackPosition: mediaPlayer.activePlayer ? mediaPlayer.activePlayer.position : 0
                    property real progress: trackLength > 0 ? Math.min(1.0, Math.max(0, trackPosition / trackLength)) : 0

                    Rectangle {
                        width: parent.progress * parent.width
                        height: parent.height
                        radius: 2
                        color: Settings.accentColor

                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.Linear } }
                    }

                    Rectangle {
                        id: mediaSliderHandle
                        x: parent.progress * (parent.width - width)
                        anchors.verticalCenter: parent.verticalCenter
                        width: sliderDragArea.containsMouse || mediaSliderDragging ? 14 : 10
                        height: width
                        radius: width / 2
                        color: sliderDragArea.containsMouse || mediaSliderDragging ? Settings.accentColor : Settings.textPrimary

                        Behavior on width { NumberAnimation { duration: 150 } }
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    MouseArea {
                        id: sliderDragArea
                        anchors.fill: parent
                        anchors.margins: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        onPressed: function(mouse) {
                            mediaSliderDragging = true;
                            updatePosition(mouse);
                        }

                        onPositionChanged: function(mouse) {
                            if (mediaSliderDragging) {
                                updatePosition(mouse);
                            }
                        }

                        onReleased: function(mouse) {
                            mediaSliderDragging = false;
                            if (mediaPlayer.activePlayer && sliderTrack.trackLength > 0) {
                                var ratio = Math.max(0, Math.min(1, (mouse.x - 8) / sliderTrack.width));
                                mediaPlayer.activePlayer.position = ratio * sliderTrack.trackLength;
                            }
                        }

                        function updatePosition(mouse) {
                            if (mediaPlayer.activePlayer && sliderTrack.trackLength > 0) {
                                var ratio = Math.max(0, Math.min(1, (mouse.x - 8) / sliderTrack.width));
                                mediaPlayer.activePlayer.position = ratio * sliderTrack.trackLength;
                            }
                        }
                    }
                }

                Text {
                    id: totalTimeText
                    text: formatTime(mediaPlayer.activePlayer ? mediaPlayer.activePlayer.length : 0)
                    font.family: helveticaFont.name
                    font.pixelSize: 11
                    color: Settings.textSecondary
                    anchors.verticalCenter: parent.verticalCenter
                    width: 36
                }
            }
        }
    }

    Row {
        id: workspaceRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 16 
        spacing: 8

        Repeater {
            model: 6

            delegate: Rectangle {
                id: dot
                
                property int wsIndex: startWorkspace + index
                property var tagInfo: getTagInfo(wsIndex)
                property bool isActive: wsIndex === activeWorkspace
                property bool hasClients: tagInfo ? tagInfo.client_count > 0 : false

                width: isActive ? 20 : 8
                height: 8
                radius: 4

                Behavior on width {
                    NumberAnimation { duration: 200; easing.type: Easing.InOutQuad }
                }

                color: {
                    if (isActive) return Settings.accentColor;
                    if (hasClients) return Settings.textPrimary;
                    return Settings.textSecondary;
                }
                
                opacity: {
                    if (isActive) return 1.0;
                    if (hasClients) return 0.8;
                    return 0.4;
                }

                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on opacity { NumberAnimation { duration: 150 } }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        switcher.view(dot.wsIndex);
                    }
                }
            }
        }
    }

    Rectangle {
        id: bellWidget
        anchors {
            left: parent.left
            leftMargin: 20 
            top: parent.top
            topMargin: 6 
        }
        height: 28
        width: 28
        color: bellMouseArea.containsMouse ? Settings.hoverColor : Settings.hoverLight
        radius: 14
        scale: bellMouseArea.containsMouse ? 1.05 : 1.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        
        Image {
            anchors.centerIn: parent
            width: 20
            height: 20
            source: "file:///home/johnnome1234/.gemini/antigravity-cli/brain/804a6ef7-4668-47f5-87ab-cfb1b789d690/coke_bottle_icon_1783299243485.jpg"
            fillMode: Image.PreserveAspectFit
            opacity: activeReminderCount > 0 ? 1.0 : 0.6
        }

        Rectangle {
            id: badge
            width: 14
            height: 14
            radius: 7
            color: Settings.notificationBadge
            anchors {
                top: parent.top
                right: parent.right
            }
            visible: activeReminderCount > 0

            Text {
                anchors.centerIn: parent
                text: activeReminderCount.toString()
                color: Settings.textOnDark
                font.pixelSize: 9
                font.bold: true
            }
        }

        MouseArea {
            id: bellMouseArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                notificationsPopupOpen = !notificationsPopupOpen;
            }
        }
    }

    Rectangle {
        id: recordWidget
        anchors {
            left: bellWidget.right
            leftMargin: 12
            top: parent.top
            topMargin: 6 
        }
        height: 28
        width: 28
        color: isRecording ? Settings.errorColor : (recordMouseArea.containsMouse ? Settings.hoverColor : Settings.hoverLight)
        radius: 14
        scale: recordMouseArea.containsMouse ? 1.05 : 1.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        
        Text {
            anchors.centerIn: parent
            text: isRecording ? "stop" : "fiber_manual_record"
            font.family: materialFont.name
            font.pixelSize: 18
            color: isRecording ? "#ffffff" : Settings.textSecondary
        }

        MouseArea {
            id: recordMouseArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                if (isRecording) {
                    Quickshell.execDetached(["pkill", "-sigint", "wf-recorder"]);
                    isRecording = false;
                } else {
                    Quickshell.execDetached(["sh", "-c", "mkdir -p ~/videos && wf-recorder -f ~/videos/screenrecord_$(date +%y%m%d_%h%m%s).mp4"]);
                    isRecording = true;
                }
            }
        }
    }

    Rectangle {
        id: wifiContainer
        anchors {
            right: parent.right
            rightMargin: 20 
            top: parent.top
            topMargin: 6 
        }
        height: 28
        width: 108
        color: (wifiPopupOpen || wifiMouseArea.containsMouse) ? Settings.hoverColor : Settings.hoverLight
        radius: 14
        scale: (wifiPopupOpen || wifiMouseArea.containsMouse) ? 1.05 : 1.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Row {
            anchors.centerIn: parent
            spacing: 5

            Text {
                text: "wifi"
                font.family: materialFont.name
                color: Settings.textPrimary
                font.pixelSize: 20
                opacity: wifiConnected ? 1.0 : 0.4
            }

            Text {
                text: "bluetooth"
                font.family: materialFont.name
                color: Settings.textPrimary
                font.pixelSize: 20
                opacity: isBluetoothOn ? 1.0 : 0.4
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: {
                    let vol = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0;
                    let muted = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.muted : false;
                    if (muted || vol === 0) return "volume_off";
                    if (vol < 0.33) return "volume_mute";
                    if (vol < 0.66) return "volume_down";
                    return "volume_up";
                }
                font.family: materialFont.name
                color: Settings.textPrimary
                font.pixelSize: 20
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: getBatteryIcon(batteryPercent, batteryCharging)
                font.family: materialFont.name
                color: batteryPercent <= 15 ? Settings.errorColor : Settings.textPrimary
                font.pixelSize: 20
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: wifiMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggleWifiPopup()
        }
    }

    PopupWindow {
        id: wifiHoverPopup
        anchor.window: window
        
        implicitWidth: 290
        property int baseHeight: 252
        property int wifiListHeight: wifiListPopupOpen ? Math.min(300, Math.max(80, wifiList.length * 42 + 50)) : 0
        property int btListHeight: bluetoothListPopupOpen ? Math.min(300, Math.max(80, (bluetoothList.length + 1) * 42 + 50)) : 0
        property int audioListHeight: audioListPopupOpen ? Math.min(300, Math.max(80, audioSinkList.length * 42 + 50)) + 12 : 0
        implicitHeight: baseHeight + Math.max(wifiListHeight, Math.max(btListHeight, audioListHeight))
        Behavior on implicitHeight { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
        
        anchor.rect.x: Math.min(window.width - width - 10, wifiContainer.x + wifiContainer.width / 2 - width / 2)
        anchor.rect.y: 45 // offset below bar
        
        visible: wifiPopupOpen || wifiContainerRect.opacity > 0.01
        color: "transparent"

        HoverHandler {
            id: wifiHoverPopupHover
        }

        Rectangle {
            id: wifiContainerRect
            anchors.fill: parent
            color: Settings.backgroundColor
            radius: 16
            border.color: Settings.borderColor
            border.width: 1

            opacity: wifiPopupOpen ? 1.0 : 0.0
            scale: wifiPopupOpen ? 1.0 : 0.95
            
            transform: Translate {
                y: (1.0 - wifiContainerRect.scale) * -100
            }

            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            Text {
                text: "battery is at " + batteryPercent + "%"
                color: Settings.textSecondary
                font.pixelSize: 12
                font.family: "Liberation Sans, sans-serif"
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 8
                anchors.rightMargin: 12
            }

            Row {
                id: brightnessRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 30
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12
                
                Text {
                    text: "brightness_7"
                    font.family: materialFont.name
                    font.pixelSize: 22
                    color: Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    width: parent.width - 38
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Process {
                        id: setBrProc
                        function setBr(val) {
                            let pc = Math.max(1, Math.round(val * 100));
                            command = ["brightnessctl", "s", pc + "%"];
                            running = true;
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Settings.borderColor

                        Rectangle {
                            width: window.currentBrightness * parent.width
                            height: parent.height
                            color: Settings.accentColor
                            radius: 2
                        }
                    }

                    Rectangle {
                        x: window.currentBrightness * (parent.width - width)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        radius: 8
                        color: brMouse.pressed ? Settings.textPrimary : Settings.accentColor
                    }

                    MouseArea {
                        id: brMouse
                        anchors.fill: parent
                        function updateBr(mouse) {
                            var pos = Math.max(0, Math.min(mouse.x, width));
                            var val = pos / width;
                            setBrProc.setBr(val);
                        }
                        onPositionChanged: (mouse) => { if (pressed) updateBr(mouse); }
                        onClicked: (mouse) => { updateBr(mouse); }
                    }
                }
            }

            Row {
                id: volumeRow
                anchors.top: brightnessRow.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 16 
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12

                Text {
                    text: {
                        let vol = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0;
                        let muted = Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.muted : false;
                        if (muted || vol === 0) return "volume_off";
                        if (vol < 0.33) return "volume_mute";
                        if (vol < 0.66) return "volume_down";
                        return "volume_up";
                    }
                    font.family: materialFont.name
                    font.pixelSize: 22
                    color: Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: customVolSlider
                    width: parent.width - 74
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter

                    PwObjectTracker {
                        objects: [Pipewire.defaultAudioSink]
                    }

                    Process {
                        id: audioSinkSetter
                        running: false
                        function setSink(idStr) {
                            command = ["wpctl", "set-default", idStr];
                            running = true;
                        }
                    }

                    Process {
                        id: volProc
                        function setVolume(vol) {
                            command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol.toFixed(2)];
                            running = true;
                        }
                    }
                    Process {
                        id: unmuteProc
                        function unmute() {
                            command = ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"];
                            running = true;
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Settings.borderColor

                        Rectangle {
                            width: (Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0) * parent.width
                            height: parent.height
                            color: Settings.accentColor
                            radius: 2
                        }
                    }

                    Rectangle {
                        id: sliderHandle
                        x: (Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio.volume : 0) * (parent.width - width)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        radius: 8
                        color: sliderMouseArea.pressed ? Settings.textPrimary : Settings.accentColor
                    }

                    MouseArea {
                        id: sliderMouseArea
                        anchors.fill: parent
                        function updateVol(mouse) {
                            var pos = Math.max(0, Math.min(mouse.x, width));
                            var vol = pos / width;
                            if (Pipewire.defaultAudioSink) {
                                try {
                                    Pipewire.defaultAudioSink.audio.volume = vol;
                                    Pipewire.defaultAudioSink.audio.muted = false;
                                } catch (e) {
                                    console.log("pipewire assignment failed: " + e);
                                }
                            }
                            volProc.setVolume(vol);
                            unmuteProc.unmute();
                        }
                        onPositionChanged: (mouse) => { if (pressed) updateVol(mouse); }
                        onClicked: (mouse) => { updateVol(mouse); }
                    }
                }

                Rectangle {
                    width: 24
                    height: 24
                    radius: 12
                    color: audioArrowMouse.containsMouse ? Settings.hoverColor : "transparent"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Text {
                        text: audioListPopupOpen ? "expand_more" : "chevron_right"
                        font.family: materialFont.name
                        color: Settings.textPrimary
                        font.pixelSize: 24
                        anchors.centerIn: parent
                    }
                    MouseArea {
                        id: audioArrowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            audioListPopupOpen = !audioListPopupOpen;
                            wifiListPopupOpen = false;
                            bluetoothListPopupOpen = false;
                        }
                    }
                }
            }

            Row {
                id: networkCardsRow
                anchors.top: audioDropdownItem.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 12
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 8

                Rectangle {
                    width: 133
                    height: 64
                    radius: 10
                    color: wifiItemMouse.containsMouse ? Settings.hoverColor : Settings.hoverLight
                    
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        width: parent.width - 12
                        
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 4
                            Text {
                                text: "wifi"
                                font.family: materialFont.name
                                color: Settings.textPrimary
                                font.pixelSize: 18
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "wi-fi"
                                color: Settings.textPrimary
                                font.pixelSize: 12
                                font.bold: true
                                font.family: "Liberation Sans, sans-serif"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        
                        Text {
                            text: wifiConnected ? wifiSSID : "disconnected"
                            color: Settings.textSecondary
                            font.pixelSize: 10
                            font.family: "Liberation Sans, sans-serif"
                            elide: Text.ElideRight
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }

                    MouseArea {
                        id: wifiItemMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            wifiListPopupOpen = !wifiListPopupOpen;
                            bluetoothListPopupOpen = false;
                            audioListPopupOpen = false;
                        }
                    }
                }

                Rectangle {
                    width: 133
                    height: 64
                    radius: 10
                    color: bluetoothItemMouse.containsMouse ? Settings.hoverColor : Settings.hoverLight
                    
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        width: parent.width - 12
                        
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 4
                            Text {
                                text: "bluetooth"
                                font.family: materialFont.name
                                color: Settings.textPrimary
                                font.pixelSize: 20
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "bluetooth"
                                color: Settings.textPrimary
                                font.pixelSize: 12
                                font.bold: true
                                font.family: "Liberation Sans, sans-serif"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        
                        Text {
                            text: isBluetoothOn ? (connectedBluetoothDevice !== "" ? connectedBluetoothDevice : "enabled") : "disabled"
                            color: Settings.textSecondary
                            font.pixelSize: 10
                            font.family: "Liberation Sans, sans-serif"
                            elide: Text.ElideRight
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }

                    MouseArea {
                        id: bluetoothItemMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            bluetoothListPopupOpen = !bluetoothListPopupOpen;
                            wifiListPopupOpen = false;
                            audioListPopupOpen = false;
                        }
                    }
                }
            }

            Row {
                id: settingsCardsRow
                anchors.top: wifiListPopupOpen ? wifiDropdownListContainer.bottom : (bluetoothListPopupOpen ? bluetoothDropdownListContainer.bottom : networkCardsRow.bottom)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 8
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 8

                Rectangle {
                    width: 133
                    height: 64
                    radius: 10
                    color: window.nightLightEnabled ? Settings.accentColor : (nightLightWidgetMouse.containsMouse ? Settings.hoverColor : Settings.hoverLight)
                    
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        width: parent.width - 12
                        
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 4
                            Text {
                                text: window.nightLightEnabled ? "brightness_3" : "brightness_7"
                                font.family: materialFont.name
                                color: window.nightLightEnabled ? Settings.backgroundColor : Settings.textPrimary
                                font.pixelSize: 18
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "night light"
                                color: window.nightLightEnabled ? Settings.backgroundColor : Settings.textPrimary
                                font.pixelSize: 12
                                font.bold: true
                                font.family: "Liberation Sans, sans-serif"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        
                        Text {
                            text: window.nightLightEnabled ? "on" : "off"
                            color: window.nightLightEnabled ? Settings.backgroundColor : Settings.textSecondary
                            font.pixelSize: 10
                            font.family: "Liberation Sans, sans-serif"
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }

                    MouseArea {
                        id: nightLightWidgetMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            window.nightLightEnabled = !window.nightLightEnabled;
                        }
                    }
                }

                Rectangle {
                    width: 133
                    height: 64
                    radius: 10
                    color: Settings.isDarkMode ? Settings.accentColor : (darkModeWidgetMouse.containsMouse ? Settings.hoverColor : Settings.hoverLight)
                    
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        width: parent.width - 12
                        
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 4
                            Text {
                                text: "brightness_4"
                                font.family: materialFont.name
                                color: Settings.isDarkMode ? Settings.backgroundColor : Settings.textPrimary
                                font.pixelSize: 18
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "dark mode"
                                color: Settings.isDarkMode ? Settings.backgroundColor : Settings.textPrimary
                                font.pixelSize: 12
                                font.bold: true
                                font.family: "Liberation Sans, sans-serif"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        
                        Text {
                            text: Settings.isDarkMode ? "on" : "off"
                            color: Settings.isDarkMode ? Settings.backgroundColor : Settings.textSecondary
                            font.pixelSize: 10
                            font.family: "Liberation Sans, sans-serif"
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }

                    MouseArea {
                        id: darkModeWidgetMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Settings.isDarkMode = !Settings.isDarkMode;
                        }
                    }
                }
            }

            Item {
                id: wifiDropdownListContainer
                anchors.top: networkCardsRow.bottom
                anchors.topMargin: 12
                anchors.left: parent.left
                anchors.right: parent.right
                height: wifiListPopupOpen ? wifiHoverPopup.wifiListHeight : 0
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                Column {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8
    
                    Text {
                        text: "available networks"
                        color: Settings.textPrimary
                        font.bold: true
                        font.pixelSize: 13
                        font.family: "Liberation Sans, sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
    
                    Flickable {
                        width: parent.width
                        height: parent.height - 35
                        contentWidth: width
                        contentHeight: wifiListColumn.implicitHeight
                        clip: true
                        visible: wifiList.length > 0
    
                        Column {
                            id: wifiListColumn
                            width: parent.width
                            spacing: 6
    
                            Repeater {
                                model: wifiList
                                delegate: Rectangle {
                                    id: delegateItem
                                    width: parent.width
                                    clip: true
                                    
                                    property bool isSelected: window.selectedSsid === modelData.ssid
                                    height: isSelected ? 76 : 36
                                    radius: 8
                                    color: (listNetMouse.containsMouse || isSelected) ? Settings.hoverColor : "transparent"
    
                                    Behavior on height { NumberAnimation { duration: 150 } }
    
                                    MouseArea {
                                        id: listNetMouse
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        height: 36
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (window.selectedSsid === modelData.ssid) {
                                                window.selectedSsid = "";
                                            } else {
                                                window.selectedSsid = modelData.ssid;
                                            }
                                        }
                                    }
    
                                    Column {
                                        width: parent.width
                                        spacing: 6
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.margins: 6
    
                                        Row {
                                            id: headerRow
                                            width: parent.width
                                            height: 24
                                            spacing: 8
    
                                            Text {
                                                text: getWifiIcon(modelData.signal, modelData.isSecure)
                                                font.family: materialFont.name
                                                color: Settings.textPrimary
                                                font.pixelSize: 18
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
    
                                            Text {
                                                text: modelData.ssid
                                                color: Settings.textPrimary
                                                font.pixelSize: 13
                                                font.family: "Liberation Sans, sans-serif"
                                                elide: Text.ElideRight
                                                width: parent.width - 60
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
    
                                            Text {
                                                text: modelData.signal + "%"
                                                color: Settings.textSecondary
                                                font.pixelSize: 11
                                                font.family: "Liberation Sans, sans-serif"
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
    
                                        Row {
                                            width: parent.width
                                            height: 30
                                            spacing: 6
                                            visible: delegateItem.isSelected
    
                                            Rectangle {
                                                width: parent.width - 70
                                                height: 28
                                                color: "#ffffff"
                                                radius: 4
                                                border.color: proxyPasswordInput.activeFocus ? Settings.accentColor : Settings.borderColor
                                                border.width: proxyPasswordInput.activeFocus ? 2 : 1
    
                                                Text {
                                                    anchors.fill: parent
                                                    anchors.margins: 4
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Settings.textPrimary
                                                    font.pixelSize: 12
                                                    font.family: "Liberation Sans, sans-serif"
                                                    text: "\u2022".repeat(proxyPasswordInput.text.length) + (proxyPasswordInput.activeFocus ? "|" : "")
                                                    clip: true
                                                }
                                                
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.IBeamCursor
                                                    onClicked: proxyPasswordInput.forceActiveFocus()
                                                }
                                            }
    
                                            Rectangle {
                                                width: 60
                                                height: 28
                                                color: connectMouse.containsMouse ? Settings.accentColor : Settings.textPrimary
                                                radius: 4
    
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: "connect"
                                                    color: Settings.textOnDark
                                                    font.pixelSize: 11
                                                    font.bold: true
                                                    font.family: "Liberation Sans, sans-serif"
                                                }
    
                                                MouseArea {
                                                    id: connectMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        wifiConnectProc.connectTo(modelData.ssid, proxyPasswordInput.text);
                                                        proxyPasswordInput.text = "";
                                                        window.selectedSsid = "";
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
    
                    Text {
                        text: "no other networks found"
                        color: Settings.textSecondary
                        font.pixelSize: 12
                        font.italic: true
                        visible: wifiList.length === 0
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }

            Item {
                id: bluetoothDropdownListContainer
                anchors.top: networkCardsRow.bottom
                anchors.topMargin: 12
                anchors.left: parent.left
                anchors.right: parent.right
                height: bluetoothListPopupOpen ? wifiHoverPopup.btListHeight : 0
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                Column {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8
    
                    Item {
                        width: parent.width
                        height: 24
                        
                        Text {
                            text: "bluetooth"
                            color: Settings.textPrimary
                            font.bold: true
                            font.pixelSize: 13
                            font.family: "Liberation Sans, sans-serif"
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                        }
                        
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8
                            
                            Rectangle {
                                width: isBluetoothScanning ? 65 : 50
                                height: 20
                                radius: 10
                                color: isBluetoothScanning ? Settings.accentColor : Settings.surfaceColor
                                visible: isBluetoothOn
                                
                                Behavior on width { NumberAnimation { duration: 150 } }
                                Behavior on color { ColorAnimation { duration: 150 } }
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: isBluetoothScanning ? "scanning..." : "scan"
                                    color: isBluetoothScanning ? Settings.textOnDark : Settings.textPrimary
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                                
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: isBluetoothScanning ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onClicked: {
                                        if (!isBluetoothScanning) {
                                            bluetoothCmdProc.scanDevices();
                                        }
                                    }
                                }
                            }
                            
                            Rectangle {
                                width: 50
                                height: 20
                                radius: 10
                                color: isBluetoothOn ? Settings.accentColor : Settings.borderColor
                                
                                Behavior on color { ColorAnimation { duration: 150 } }
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: isBluetoothOn ? "on" : "off"
                                    color: Settings.textOnDark
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                                
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        bluetoothCmdProc.togglePower(!isBluetoothOn);
                                    }
                                }
                            }
                        }
                    }
    
                    Flickable {
                        width: parent.width
                        height: parent.height - 35
                        contentWidth: width
                        contentHeight: btListColumn.implicitHeight
                        clip: true
                        visible: isBluetoothOn && bluetoothList.length > 0
    
                        Column {
                            id: btListColumn
                            width: parent.width
                            spacing: 6
    
                            Repeater {
                                model: bluetoothList
                                delegate: Rectangle {
                                    id: btDelegateItem
                                    width: parent.width
                                    height: 36
                                    radius: 8
                                    color: btDelegateMouse.containsMouse ? Settings.hoverColor : "transparent"
    
                                    Row {
                                        width: parent.width
                                        height: 24
                                        spacing: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.margins: 6
    
                                        Text {
                                            text: modelData.status === "connected" ? "bluetooth_connected" : "bluetooth"
                                            font.family: materialFont.name
                                            color: modelData.status === "connected" ? Settings.accentColor : Settings.textPrimary
                                            font.pixelSize: 18
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
    
                                        Text {
                                            text: modelData.name
                                            color: Settings.textPrimary
                                            font.pixelSize: 12
                                            font.family: "Liberation Sans, sans-serif"
                                            elide: Text.ElideRight
                                            width: parent.width - 120
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
    
                                        Text {
                                            text: modelData.status === "connected" ? "connected" : (modelData.status === "paired" ? "paired" : "not paired")
                                            color: modelData.status === "connected" ? Settings.accentColor : Settings.textSecondary
                                            font.pixelSize: 10
                                            font.family: "Liberation Sans, sans-serif"
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
    
                                    MouseArea {
                                        id: btDelegateMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.status === "connected") {
                                                bluetoothCmdProc.disconnectDevice(modelData.mac);
                                            } else {
                                                bluetoothCmdProc.connectDevice(modelData.mac);
                                            }
                                        }
                                    }
                                    
                                    Rectangle {
                                        width: 24
                                        height: 24
                                        radius: 12
                                        color: forgetMouse.containsMouse ? Settings.hoverColor : "transparent"
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        
                                        Text {
                                            text: "close"
                                            font.family: materialFont.name
                                            color: Settings.textPrimary
                                            font.pixelSize: 14
                                            anchors.centerIn: parent
                                        }
                                        
                                        MouseArea {
                                            id: forgetMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                bluetoothCmdProc.removeDevice(modelData.mac);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                }
            }

            Item {
                id: audioDropdownItem
                anchors.top: volumeRow.bottom
                anchors.topMargin: 0
                anchors.left: parent.left
                anchors.right: parent.right
                height: audioListPopupOpen ? wifiHoverPopup.audioListHeight : 0
                clip: true
                Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                
                Column {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: 12
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    height: Math.max(0, parent.height - 24)
                    spacing: 8
    
                    Text {
                        text: "audio devices"
                        color: Settings.textPrimary
                        font.bold: true
                        font.pixelSize: 13
                        font.family: "Liberation Sans, sans-serif"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
    
                    Flickable {
                        width: parent.width
                        height: Math.max(0, parent.height - 35)
                        contentHeight: audioListColumn.implicitHeight
                        clip: true
    
                        Column {
                            id: audioListColumn
                            width: parent.width
                            spacing: 4
                            
                            Repeater {
                                model: audioSinkList
                                delegate: Rectangle {
                                    width: parent.width
                                    height: 38
                                    radius: 8
                                    color: itemMouse.containsMouse ? Settings.hoverColor : (modelData.active ? Settings.hoverColor : "transparent")
                                    
                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        spacing: 12
                                        
                                        Text {
                                            text: "speaker"
                                            font.family: materialFont.name
                                            color: modelData.active ? Settings.accentColor : Settings.textPrimary
                                            font.pixelSize: 18
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        
                                        Text {
                                            text: modelData.name
                                            color: modelData.active ? Settings.accentColor : Settings.textPrimary
                                            font.pixelSize: 12
                                            font.family: "Liberation Sans, sans-serif"
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 40
                                            elide: Text.ElideRight
                                        }
                                    }
                                    
                                    MouseArea {
                                        id: itemMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            audioSinkSetter.setSink(modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }



    Rectangle {
        id: timeContainer
        anchors {
            right: wifiContainer.left
            rightMargin: 10 
            top: parent.top
            topMargin: 6 
        }
        height: 28
        width: clockRow.width + 24
        color: isCalendarHovered ? Settings.hoverColor : Settings.hoverLight 
        radius: height / 2
        scale: isCalendarHovered ? 1.05 : 1.0 

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Row {
            id: clockRow
            anchors.centerIn: parent
            spacing: 5

            Text {
                text: "calendar_today"
                font.family: materialFont.name
                color: Settings.textPrimary
                font.pixelSize: 18
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                id: timeText
                text: Qt.formatDateTime(GlobalClock.date, "hh:mm ap")
                color: Settings.textPrimary
                font.pixelSize: 18
                font.bold: false
                font.family: helveticaFont.name
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: timeMouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggleCalendarPopup()
        }
    }

    PopupWindow {
        id: calendarPopup
        anchor.window: window
        
        implicitWidth: 300
        implicitHeight: 330
        
        anchor.rect.x: Math.max(10, Math.min(window.width - width - 10, timeContainer.x + timeContainer.width / 2 - width / 2))
        anchor.rect.y: 45 
        
        visible: popupOpen || container.opacity > 0.01
        color: "transparent"

        Rectangle {
            id: container
            anchors.fill: parent
            color: Settings.backgroundColor 
            radius: 20
            border.color: Settings.borderColor
            border.width: 1

            opacity: popupOpen ? 1.0 : 0.0
            scale: popupOpen ? 1.0 : 0.95
            
            transform: Translate {
                y: (1.0 - container.scale) * -100
            }

            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            HoverHandler {
                id: calendarHover
            }

            MouseArea {
                id: calendarMouseArea
                anchors.fill: parent
                onClicked: {
                    editorOpen = false;
                }
            }

            Text {
                id: headerText
                text: Qt.formatDateTime(GlobalClock.date, "MMMM yyyy")
                color: Settings.textPrimary
                font.pixelSize: 16
                font.bold: true
                font.family: "Inter, Noto Sans, sans-serif"
                anchors {
                    top: parent.top
                    topMargin: 16
                    horizontalCenter: parent.horizontalCenter
                }
            }

            Grid {
                id: weekdayGrid
                columns: 7
                spacing: 8
                anchors {
                    top: headerText.bottom
                    topMargin: 12
                    horizontalCenter: parent.horizontalCenter
                }
                Repeater {
                    model: ["su", "mo", "tu", "we", "th", "fr", "sa"]
                    delegate: Text {
                        text: modelData
                        color: Settings.textSecondary
                        font.pixelSize: 12
                        font.bold: true
                        font.family: "Inter, Noto Sans, sans-serif"
                        width: 32
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Grid {
                id: daysGrid
                columns: 7
                spacing: 8
                anchors {
                    top: weekdayGrid.bottom
                    topMargin: 8
                    horizontalCenter: parent.horizontalCenter
                }
                Repeater {
                    model: getDaysForMonth(GlobalClock.date)
                    delegate: Rectangle {
                        id: dayCell
                        width: 32
                        height: 32
                        radius: 16
                        
                        property bool isToday: modelData !== "" && parseInt(modelData) === GlobalClock.date.getDate()
                        property bool isSelected: modelData !== "" && selectedDateString === getDateString(modelData)
                        property bool isHovered: dayMouseArea.containsMouse
                        
                        color: {
                            if (modelData === "") return "transparent";
                            if (isToday) return Settings.textPrimary;
                            if (isSelected) return Settings.accentColor;
                            if (isHovered) return Settings.surfaceColor;
                            return "transparent";
                        }
                        
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: {
                                if (modelData === "") return "transparent";
                                if (isToday || isSelected) return Settings.textOnDark;
                                return Settings.textPrimary;
                            }
                            font.pixelSize: 13
                            font.bold: isToday || isSelected
                            font.family: "Inter, Noto Sans, sans-serif"
                            opacity: modelData === "" ? 0 : 1
                        }

                        Rectangle {
                            width: 4
                            height: 4
                            radius: 2
                            color: (isToday || isSelected) ? Settings.textOnDark : Settings.accentColor
                            anchors {
                                bottom: parent.bottom
                                bottomMargin: 3
                                horizontalCenter: parent.horizontalCenter
                            }
                            visible: modelData !== "" && reminders[getDateString(modelData)] !== undefined && reminders[getDateString(modelData)] !== ""
                        }

                        MouseArea {
                            id: dayMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            visible: modelData !== ""
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                selectedDateString = getDateString(modelData);
                                clickedDayY = dayCell.y + daysGrid.y;
                                var reminderText = reminders[selectedDateString] || "";
                                descriptionInput.text = reminderText;
                                editorOpen = true;
                            }
                        }
                    }
                }
            }
        }
    }

    MouseArea {
        id: panelDismissArea
        anchors.fill: parent
        visible: editorOpen && popupOpen
        onClicked: {
            editorOpen = false;
        }
    }

    Rectangle {
        id: editorContainer
        width: 210
        height: 160
        
        x: calendarPopup.anchor.rect.x - width - 12
        y: 45 + Math.max(10, Math.min(330 - height - 10, clickedDayY - height / 2 + 16))
        
        color: Settings.backgroundColor
        radius: 16
        border.color: Settings.borderColor
        border.width: 1
        
        property bool active: editorOpen && popupOpen
        visible: active || opacity > 0.01
        opacity: active ? 1.0 : 0.0
        scale: active ? 1.0 : 0.8
        
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
        
        onVisibleChanged: {
            if (visible) {
                descriptionInput.forceActiveFocus();
            }
        }

        HoverHandler {
            id: editorHover
        }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10
            
            Text {
                text: formatSelectedDate(selectedDateString)
                color: Settings.textPrimary
                font.bold: true
                font.pixelSize: 13
                font.family: "Inter, Noto Sans, sans-serif"
                anchors.horizontalCenter: parent.horizontalCenter
            }
            
            Rectangle {
                id: inputContainer
                width: parent.width
                height: 50
                color: Settings.textOnDark
                radius: 8
                border.color: descriptionInput.activeFocus ? Settings.accentColor : Settings.borderColor
                border.width: 1
                
                TextInput {
                    id: descriptionInput
                    anchors.fill: parent
                    anchors.margins: 6
                    color: Settings.textPrimary
                    font.pixelSize: 12
                    font.family: "Inter, Noto Sans, sans-serif"
                    clip: true
                    focus: true
                    
                    Text {
                        text: "add reminder..."
                        color: Settings.textSecondary
                        font.pixelSize: 12
                        font.italic: true
                        visible: descriptionInput.text === "" && !descriptionInput.activeFocus
                    }
                }
            }
            
            Row {
                spacing: 8
                anchors.horizontalCenter: parent.horizontalCenter
                
                Rectangle {
                    width: 85
                    height: 28
                    radius: 6
                    color: saveMouseArea.containsMouse ? Settings.activeAccent : Settings.accentColor
                    
                    Text {
                        anchors.centerIn: parent
                        text: "save"
                        color: Settings.textOnDark
                        font.bold: true
                        font.pixelSize: 11
                    }
                    
                    MouseArea {
                        id: saveMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            saveReminder(selectedDateString, descriptionInput.text);
                            editorOpen = false;
                        }
                    }
                }
                
                Rectangle {
                    width: 85
                    height: 28
                    radius: 6
                    color: deleteMouseArea.containsMouse ? Settings.errorColor : Settings.textPrimary
                    
                    Text {
                        anchors.centerIn: parent
                        text: "delete"
                        color: Settings.textOnDark
                        font.bold: true
                        font.pixelSize: 11
                    }
                    
                    MouseArea {
                        id: deleteMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            saveReminder(selectedDateString, "");
                            descriptionInput.text = "";
                            editorOpen = false;
                        }
                    }
                }
            }
        }
    }

    PopupWindow {
        id: notificationPopup
        anchor.window: window
        anchor.rect.x: window.width - width - 20
        anchor.rect.y: 45
        
        implicitWidth: 320
        implicitHeight: 80
        
        visible: (notificationActive || isSystemNotificationActive) && containerRect.opacity > 0.01
        color: "transparent"
        
        Rectangle {
            id: containerRect
            anchors.fill: parent
            color: Settings.textPrimary
            radius: 16
            border.color: Settings.borderColor
            border.width: 1
            
            opacity: (notificationActive || isSystemNotificationActive) ? 1.0 : 0.0
            scale: (notificationActive || isSystemNotificationActive) ? 1.0 : 0.8
            
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
            
            Row {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12
                
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: isSystemNotificationActive && currentSystemNotification.icon ? "transparent" : Settings.accentColor
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Image {
                        anchors.centerIn: parent
                        source: (currentSystemNotification && currentSystemNotification.icon !== "") ? (currentSystemNotification.icon.startsWith("image:// icon ") ? currentsystemnotification.icon : "image: icon " + currentsystemnotification.icon) + "?fallback dialog information" : quickshell.iconpath("preferences system notifications", "dialog information")
                        sourceSize.width: (currentSystemNotification && currentSystemNotification.icon !== "") ? 36 : 20
                        sourceSize.height: (currentSystemNotification && currentSystemNotification.icon !== "") ? 36 : 20
                        fillMode: Image.PreserveAspectFit
                    }
                }
                
                Column {
                    width: parent.width - 36 - 12 - 24 - 12 
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    
                    Text {
                        text: isSystemNotificationActive ? currentSystemNotification.title : "reminder for today"
                        color: Settings.textOnDark
                        font.bold: true
                        font.pixelSize: 13
                        font.family: "Inter, Noto Sans, sans-serif"
                    }
                    
                    Text {
                        text: isSystemNotificationActive ? currentSystemNotification.body : todayReminderText
                        color: Settings.borderColor
                        font.pixelSize: 12
                        font.family: "Inter, Noto Sans, sans-serif"
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                    }
                }
                
                Rectangle {
                    width: 24
                    height: 24
                    radius: 12
                    color: "transparent"
                    anchors.verticalCenter: parent.verticalCenter
                    
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: dismissMouseArea.containsMouse ? Settings.textOnDark : Settings.textSecondary
                        font.pixelSize: 14
                        font.bold: true
                    }
                    
                    MouseArea {
                        id: dismissMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (isSystemNotificationActive) {
                                currentSystemNotification = null;
                            } else {
                                var copy = Object.assign({}, dismissedNotifications);
                                copy[todayDateString] = true;
                                dismissedNotifications = copy;
                            }
                        }
                    }
                }
            }
        }
    }

    PopupWindow {
        id: allNotificationsPopup
        anchor.window: window
        
        anchor.rect.x: Math.max(10, Math.min(window.width - width - 10, bellWidget.x + bellWidget.width / 2 - width / 2))
        anchor.rect.y: 45
        
        implicitWidth: 320
        implicitHeight: Math.min(500, Math.max(150, notificationCount * 80 + activeReminderCount * 50 + 60))
        
        visible: notificationsPopupOpen
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: Settings.backgroundColor
            radius: 20
            border.color: Settings.borderColor
            border.width: 1
            
            opacity: allNotificationsPopup.visible ? 1.0 : 0.0
            scale: allNotificationsPopup.visible ? 1.0 : 0.95
            
            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            HoverHandler {
                id: notificationsHover
            }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10
                
                Item {
                    width: parent.width
                    height: 20
                    
                    Text {
                        text: "notifications"
                        color: Settings.textPrimary
                        font.bold: true
                        font.pixelSize: 14
                        font.family: "Inter, Noto Sans, sans-serif"
                        anchors.centerIn: parent
                    }
                    
                    Text {
                        text: "clear all"
                        color: clearAllMouse.containsMouse ? Settings.errorColor : Settings.accentColor
                        font.bold: true
                        font.pixelSize: 10
                        font.family: "Inter, Noto Sans, sans-serif"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea {
                            id: clearAllMouse
                            anchors.fill: parent
                            anchors.margins: -5
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var notifs = notificationServer.trackedNotifications.values;
                                for (var i = 0; i < notifs.length; i++) {
                                    notifs[i].tracked = false;
                                }
                                activeNotifications = [];
                            }
                        }
                    }
                }

                Flickable {
                    width: parent.width
                    height: parent.height - 40
                    contentWidth: width
                    contentHeight: notificationsColumn.implicitHeight
                    clip: true
                    visible: notificationCount > 0 || activeReminderCount > 0

                    Column {
                        id: notificationsColumn
                        width: parent.width
                        spacing: 8
                        
                        Repeater {
                            model: getRemindersList()
                            delegate: Rectangle {
                                width: parent.width
                                height: 42
                                color: Settings.textOnDark
                                radius: 8
                                border.color: Settings.borderColor
                                border.width: 1

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 8

                                    Column {
                                        width: parent.width - 24
                                        anchors.verticalCenter: parent.verticalCenter

                                        Text {
                                            text: formatSelectedDate(modelData.date)
                                            color: Settings.accentColor
                                            font.bold: true
                                            font.pixelSize: 10
                                            font.family: "Inter, Noto Sans, sans-serif"
                                        }

                                        Text {
                                            text: modelData.description
                                            color: Settings.textPrimary
                                            font.pixelSize: 12
                                            font.family: "Inter, Noto Sans, sans-serif"
                                            elide: Text.ElideRight
                                        }
                                    }

                                    // close indicator next to item
                                    Text {
                                        text: "✕"
                                        color: deleteItemMouse.containsMouse ? Settings.errorColor : Settings.textSecondary
                                        font.pixelSize: 12
                                        font.bold: true
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            id: deleteItemMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                saveReminder(modelData.date, "");
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: activeNotifications
                            delegate: Rectangle {
                                width: parent.width
                                height: notifCol.implicitHeight + 16
                                color: Settings.textOnDark
                                radius: 8
                                border.color: Settings.borderColor
                                border.width: 1

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 8
                                    
                                    Rectangle {
                                        width: 24
                                        height: 24
                                        radius: 12
                                        color: (modelData.appIcon || modelData.image) ? "transparent" : Settings.accentColor
                                        anchors.top: parent.top
                                        
                                        Image {
                                            anchors.centerIn: parent
                                            property string iconSrc: modelData.appIcon ? modelData.appIcon : (modelData.image ? modelData.image : "")
                                            source: iconSrc ? (iconSrc.startsWith("image:// icon ") ? iconsrc : "image: icon " + iconsrc) + "?fallback dialog information" : quickshell.iconpath("preferences system notifications", "dialog information")
                                            sourceSize.width: iconSrc ? 24 : 14
                                            sourceSize.height: iconSrc ? 24 : 14
                                            fillMode: Image.PreserveAspectFit
                                        }
                                    }

                                    Column {
                                        width: parent.width - 32
                                        spacing: 4
                                        id: notifCol

                                        Text {
                                            visible: modelData.appName !== "notify-send"
                                            text: modelData.appName ? modelData.appName : "notification"
                                            color: Settings.accentColor
                                            font.bold: true
                                            font.pixelSize: 10
                                            font.family: "Inter, Noto Sans, sans-serif"
                                            width: parent.width - 24
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            text: modelData.summary ? modelData.summary : ""
                                            color: Settings.textPrimary
                                            font.pixelSize: 12
                                            font.bold: true
                                            font.family: "Inter, Noto Sans, sans-serif"
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                        }
                                        
                                        Text {
                                            text: modelData.body ? modelData.body : ""
                                            color: Settings.textSecondary
                                            font.pixelSize: 11
                                            font.family: "Inter, Noto Sans, sans-serif"
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            visible: text !== ""
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Text {
                text: "no new notifications"
                color: Settings.textSecondary
                font.pixelSize: 12
                font.italic: true
                visible: notificationCount === 0 && activeReminderCount === 0
                anchors.centerIn: parent
            }
        }
    }

    Item {
        id: launcherPopup
        
        property bool launcherPowerMenuOpen: false
        
        Process {
            id: powerOffProc
            command: ["systemctl", "poweroff"]
        }
        Process {
            id: rebootProc
            command: ["systemctl", "reboot"]
        }
        Process {
            id: suspendProc
            command: ["systemctl", "suspend"]
        }
        
        Process {
            id: weatherProc
            command: ["curl", "-s", "https:// api.open meteo.com v1 forecast?latitude 37.3394&longitude 121.895&current weather true&temperature unit fahrenheit"]
            running: false
            property string temperature: "--"
            property string icon: "wb_sunny"
            
            function getIcon(code) {
                if (code === 0) return "wb_sunny";
                if (code === 1 || code === 2 || code === 3) return "cloud";
                if (code >= 45 && code <= 48) return "dehaze";
                if (code >= 51 && code <= 67) return "water_drop";
                if (code >= 71 && code <= 77) return "ac_unit";
                if (code >= 80 && code <= 82) return "water_drop";
                if (code >= 95 && code <= 99) return "flash_on";
                return "wb_sunny";
            }
            
            stdout: SplitParser {
                onRead: data => {
                    try {
                        var json = JSON.parse(data);
                        if (json && json.current_weather) {
                            weatherProc.temperature = Math.round(json.current_weather.temperature) + "°f";
                            weatherProc.icon = weatherProc.getIcon(json.current_weather.weathercode);
                        }
                    } catch (e) {}
                }
            }
        }
        
        Timer {
            id: weatherTimer
            interval: 1800000 // thirty minutes
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                weatherProc.running = true;
            }
        }

        width: 400
        height: 500
        
        x: parent.width / 2 - width / 2
        y: 50
        z: 999

        visible: launcherOpen || launcherPopupRect.opacity > 0.01
        
        Rectangle {
            id: launcherPopupRect
            anchors.fill: parent
            color: Settings.backgroundColor
            radius: 16
            border.color: Settings.borderColor
            border.width: 1

            opacity: launcherOpen ? 1.0 : 0.0
            scale: launcherOpen ? 1.0 : 0.95

            transform: Translate {
                y: (1.0 - launcherPopupRect.scale) * -100
            }

            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            Column {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                Row {
                    width: parent.width
                    height: 40
                    spacing: 8
                    
                    Rectangle {
                        width: parent.width - 146
                        height: 40
                        radius: 8
                        color: Settings.surfaceColor
                    
                    TextInput {
                        id: launcherSearchInput
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        font.family: helveticaFont.name
                        font.pixelSize: 16
                        color: Settings.textPrimary
                        selectionColor: Settings.accentColor
                        focus: launcherOpen
                        
                        onVisibleChanged: {
                            if (visible && launcherOpen) {
                                forceActiveFocus();
                            }
                        }
                        
                        onTextChanged: {
                            let query = text.toLowerCase();
                            if (query === "") {
                                filteredApps = DesktopEntries.applications.values;
                            } else {
                                let allApps = DesktopEntries.applications.values;
                                let results = [];
                                for (let i = 0; i < allApps.length; i++) {
                                    let app = allApps[i];
                                    if ((app.name && app.name.toLowerCase().indexOf(query) !== -1) ||
                                        (app.genericName && app.genericName.toLowerCase().indexOf(query) !== -1)) {
                                        results.push(app);
                                    }
                                }
                                filteredApps = results;
                            }
                            launcherList.currentIndex = 0;
                        }
                        
                        onAccepted: {
                            let item = filteredApps[launcherList.currentIndex];
                            if (item) {
                                item.execute();
                                launcherOpen = false;
                            }
                        }
                        
                        Keys.onPressed: function(event) {
                            if (event.key === Qt.Key_Escape) {
                                launcherOpen = false;
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down) {
                                launcherList.currentIndex = Math.min(launcherList.count - 1, launcherList.currentIndex + 1);
                                launcherList.positionViewAtIndex(launcherList.currentIndex, ListView.Contain);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up) {
                                launcherList.currentIndex = Math.max(0, launcherList.currentIndex - 1);
                                launcherList.positionViewAtIndex(launcherList.currentIndex, ListView.Contain);
                                event.accepted = true;
                            }
                        }
                    }
                }
                
                Rectangle {
                        width: 90
                        height: 40
                        radius: 8
                        color: Settings.surfaceColor
                        
                        Row {
                            anchors.centerIn: parent
                            spacing: 4
                            Text {
                                text: weatherProc.icon
                                font.family: materialFont.name
                                font.pixelSize: 18
                                anchors.verticalCenter: parent.verticalCenter
                                color: Settings.textPrimary
                            }
                            Text {
                                text: weatherProc.temperature
                                font.family: helveticaFont.name
                                font.pixelSize: 16
                                anchors.verticalCenter: parent.verticalCenter
                                color: Settings.textPrimary
                                font.bold: true
                            }
                        }
                    }

                Rectangle {
                        width: 40
                        height: 40
                        radius: 8
                        color: launcherPowerBtnArea.containsMouse ? Settings.errorColor : Settings.surfaceColor
                        
                        Text {
                            text: "power_settings_new"
                            font.family: materialFont.name
                            font.pixelSize: 24
                            anchors.centerIn: parent
                            color: launcherPowerBtnArea.containsMouse ? "#ffffff" : Settings.textPrimary
                        }
                        
                        MouseArea {
                            id: launcherPowerBtnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                launcherPopup.launcherPowerMenuOpen = !launcherPopup.launcherPowerMenuOpen;
                                if (!launcherPopup.launcherPowerMenuOpen) {
                                    launcherFocusTimer.start();
                                }
                            }
                        }
                        
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                }

                // app list or power menu
                Item {
                    width: parent.width
                    height: parent.height - 52

                    ListView {
                        id: launcherList
                        anchors.fill: parent
                        visible: !launcherPopup.launcherPowerMenuOpen
                        clip: true
                        spacing: 4
                    model: filteredApps
                    currentIndex: 0
                    
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: 48
                        radius: 8
                        color: (ListView.isCurrentItem || appMouseArea.containsMouse) ? Settings.borderColor : "transparent"
                        
                        Row {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 12
                            
                            Image {
                                width: 32
                                height: 32
                                anchors.verticalCenter: parent.verticalCenter
                                source: Quickshell.iconPath(modelData.icon, "application-x-executable")
                                sourceSize.width: 32
                                sourceSize.height: 32
                            }
                            
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    text: modelData.name || ""
                                    font.family: helveticaFont.name
                                    font.pixelSize: 14
                                    color: Settings.textPrimary
                                    font.bold: true
                                }
                                Text {
                                    text: modelData.genericName || modelData.comment || ""
                                    font.family: helveticaFont.name
                                    font.pixelSize: 11
                                    color: Settings.textSecondary
                                    elide: Text.ElideRight
                                    width: 300
                                    visible: text !== ""
                                }
                            }
                        }
                        
                        MouseArea {
                            id: appMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                modelData.execute();
                                launcherOpen = false;
                            }
                        }
                    }
                    }
                    
                    Column {
                        anchors.centerIn: parent
                        spacing: 20
                        visible: launcherPopup.launcherPowerMenuOpen

                        Rectangle {
                            width: 250
                            height: 60
                            radius: 12
                            color: powerOffMouse.containsMouse ? Settings.errorColor : Settings.surfaceColor
                            Row {
                                anchors.centerIn: parent
                                spacing: 16
                                Text {
                                    text: "power_settings_new"
                                    font.family: materialFont.name
                                    font.pixelSize: 28
                                    color: powerOffMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                                Text {
                                    text: "power off"
                                    font.family: helveticaFont.name
                                    font.pixelSize: 20
                                    font.bold: true
                                    color: powerOffMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                            }
                            MouseArea {
                                id: powerOffMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: powerOffProc.running = true
                            }
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        Rectangle {
                            width: 250
                            height: 60
                            radius: 12
                            color: restartMouse.containsMouse ? Settings.accentColor : Settings.surfaceColor
                            Row {
                                anchors.centerIn: parent
                                spacing: 16
                                Text {
                                    text: "restart_alt"
                                    font.family: materialFont.name
                                    font.pixelSize: 28
                                    color: restartMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                                Text {
                                    text: "restart"
                                    font.family: helveticaFont.name
                                    font.pixelSize: 20
                                    font.bold: true
                                    color: restartMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                            }
                            MouseArea {
                                id: restartMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: rebootProc.running = true
                            }
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        Rectangle {
                            width: 250
                            height: 60
                            radius: 12
                            color: suspendMouse.containsMouse ? Settings.accentColor : Settings.surfaceColor
                            Row {
                                anchors.centerIn: parent
                                spacing: 16
                                Text {
                                    text: "bedtime"
                                    font.family: materialFont.name
                                    font.pixelSize: 28
                                    color: suspendMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                                Text {
                                    text: "suspend"
                                    font.family: helveticaFont.name
                                    font.pixelSize: 20
                                    font.bold: true
                                    color: suspendMouse.containsMouse ? "#ffffff" : Settings.textPrimary
                                }
                            }
                            MouseArea {
                                id: suspendMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    suspendProc.running = true
                                    launcherOpen = false
                                }
                            }
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }
                }
            }
        }


    PopupWindow {
        id: osdPopup
        anchor.window: window
        
        anchor.rect.x: window.width / 2 - 125
        anchor.rect.y: 80
        
        implicitWidth: 250
        implicitHeight: 60
        color: "transparent"
        visible: window.osdVisible || osdRect.opacity > 0.01

        Rectangle {
            id: osdRect
            anchors.fill: parent
            radius: Settings.cornerRadius
            color: Settings.backgroundColor
            border.color: Settings.borderColor
            border.width: 1
            opacity: window.osdVisible ? 1.0 : 0.0
            scale: window.osdVisible ? 1.0 : 0.95
            Behavior on opacity { NumberAnimation { duration: 200 } }
            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

            Row {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 16

                Text {
                    text: window.osdIcon
                    font.family: materialFont.name
                    font.pixelSize: 24
                    color: Settings.textPrimary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    width: parent.width - 60
                    height: 8
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 4
                    color: Settings.hoverLight

                    Rectangle {
                        width: Math.max(0, parent.width * window.osdValue)
                        height: parent.height
                        radius: 4
                        color: Settings.accentColor
                        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }
    Process {
        id: wlsunsetProc
        command: ["wlsunset", "-T", "4001", "-t", "4000"]
        running: window.nightLightEnabled
    }
}
}
