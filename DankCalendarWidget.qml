import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

// Next-event countdown for dcal / DankCalendar, click model borrowed from
// dms-dankmail: left click opens a popout with today's events (click one to
// open its details in DankCalendar), right click refreshes, middle click
// toggles the DankCalendar window. Hovering the pill still shows the
// next-event tooltip.
PluginComponent {
    id: root

    property string eventSummary: ""
    property string eventStart: ""
    property string eventEnd: ""
    property bool eventAllDay: false
    property bool isLoading: true
    property int refreshInterval: (pluginData.refreshInterval || 30) * 1000
    property int pillMaxWidth: pluginData.pillMaxWidth || 160
    property bool dynamicWidth: pluginData.dynamicWidth ?? false
    property int lookAheadDays: pluginData.lookAheadDays || 1
    property int nowWindowMinutes: pluginData.nowWindowMinutes ?? 5
    property bool showTooltip: pluginData.showTooltip ?? true
    property real countdownNow: Date.now()
    property real remainingMs: {
        if (!eventStart)
            return -1;

        var startMs = eventDate(eventStart, eventAllDay).getTime();
        return startMs - countdownNow;
    }
    property bool isNow: {
        if (nowWindowMinutes <= 0 || eventStart === "" || remainingMs > 0)
            return false;

        var startMs = eventDate(eventStart, eventAllDay).getTime();
        var endMs = eventEnd ? eventDate(eventEnd, eventAllDay).getTime() : startMs;
        var duration = endMs - startMs;
        var maxWindow = nowWindowMinutes * 60000;
        var nowWindow = duration < maxWindow ? duration : maxWindow;
        return countdownNow < startMs + nowWindow;
    }
    property bool isLessThanOneMin: !isNow && remainingMs > 0 && remainingMs < 60000
    property bool hasEvent: eventSummary !== ""
    property string timeText: formatTimeRemaining()
    property string compactTimeText: formatCompactTimeRemaining()
    property color timeColor: Theme.primary
    property string scriptPath: PluginService.pluginDirectory + "/dankCalendarAgenda/get-next-event"
    property string agendaScriptPath: PluginService.pluginDirectory + "/dankCalendarAgenda/get-agenda-events"
    property int agendaPastDays: pluginData.agendaPastDays ?? 7
    property int agendaFutureDays: pluginData.agendaFutureDays || 30
    property var agendaEvents: []
    property var agendaModel: []
    property int agendaContentHeight: 0
    property int agendaTodayOffset: 0
    property bool agendaLoading: true
    readonly property int upcomingCount: {
        var n = 0;
        for (var i = 0; i < agendaEvents.length; i++) {
            var ev = agendaEvents[i];
            if (eventDate(ev.end || ev.start, ev.allDay).getTime() >= countdownNow)
                n++;

        }
        return n;
    }

    // Left click opens the popout (automatic when popoutContent is set);
    // right click re-fetches both the countdown and today's list; middle
    // click (MouseArea in each pill) toggles the DankCalendar window.
    pillRightClickAction: () => root.refreshAll()

    function formatTimeRemaining() {
        if (!hasEvent)
            return "";

        if (isNow)
            return "Now";

        if (isLessThanOneMin)
            return "<1m";

        if (remainingMs < 0)
            return "";

        var totalMinutes = Math.floor(remainingMs / 60000);
        var days = Math.floor(totalMinutes / 1440);
        var hours = Math.floor((totalMinutes % 1440) / 60);
        var minutes = totalMinutes % 60;
        var parts = [];
        if (days > 0)
            parts.push(days + "d");

        if (hours > 0)
            parts.push(hours + "h");

        if (minutes > 0)
            parts.push(minutes + "m");

        return parts.join("") || "<1m";
    }

    function formatCompactTimeRemaining() {
        if (!hasEvent)
            return "";
        if (isNow)
            return "Now";
        if (isLessThanOneMin)
            return "<1m";
        if (remainingMs < 0)
            return "";

        var totalMinutes = Math.floor(remainingMs / 60000);
        var days = Math.floor(totalMinutes / 1440);
        if (days > 0)
            return days + "d";
        var hours = Math.floor(totalMinutes / 60);
        if (hours > 0)
            return hours + "h";
        return Math.max(1, totalMinutes) + "m";
    }

    function parseLine(line) {
        var idx = line.indexOf("=");
        if (idx < 0)
            return ;

        var key = line.substring(0, idx);
        var val = line.substring(idx + 1);
        switch (key) {
        case "EVENT_SUMMARY":
            eventSummary = val;
            break;
        case "EVENT_START":
            eventStart = val;
            break;
        case "EVENT_END":
            eventEnd = val;
            break;
        case "EVENT_ALL_DAY":
            eventAllDay = val === "true";
            break;
        }
    }

    function toggleDcal() {
        Quickshell.execDetached(["dcal", "ipc", "ui.toggle", "view=day"]);
    }

    function openEvent(ev) {
        // events.list gives the occurrence start, which ui.openEvent needs
        // to resolve recurring events; for one-offs it matches and is inert.
        Quickshell.execDetached(["dcal", "ipc", "ui.openEvent", "uid=" + ev.uid, "start=" + ev.start]);
    }

    function newEvent() {
        // ui.newEvent opens the editor directly (dcal > 0.2.2); older
        // daemons reject the unknown method, so fall back to day view,
        // where a click on a time slot creates an event.
        Quickshell.execDetached(["sh", "-c", "dcal ipc ui.newEvent || exec dcal ipc ui.show view=day"]);
    }

    function refreshAll() {
        root.isLoading = true;
        root.agendaLoading = true;
        if (!fetchProcess.running)
            fetchProcess.running = true;

        if (!agendaProcess.running)
            agendaProcess.running = true;

    }

    function dateKey(d) {
        return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
    }

    // dcal serialises all-day events as UTC midnight of the calendar date:
    // "2026-08-08T00:00:00Z" means "8 August", not an instant. Reading that
    // back with the local getters lands a day early in any negative UTC offset
    // (PDT: 7 August 17:00), which put the trip on the wrong day and made the
    // pill count down to 17:00. Rebuild all-day dates on LOCAL midnight so
    // every consumer — grouping, headers, sorting, phase, countdown — agrees
    // with the calendar date the user typed. Timed events are real instants
    // and pass through untouched.
    function eventDate(iso, allDay) {
        var d = new Date(iso);
        if (allDay === true)
            return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());

        return d;
    }

    // Qt.formatDate() converts the JS Date to a QDate in UTC, so it prints the
    // wrong day whenever local time and UTC straddle midnight (a "Today"
    // header reading tomorrow's date). Qt.formatDateTime() keeps local time
    // and takes the same date-only format strings.
    function formatLocalDate(d, fmt) {
        return Qt.formatDateTime(d, fmt);
    }

    // Flattens the sorted events into display rows: a "week" divider when
    // the week (Monday-keyed) changes, a shaded "day" header per date,
    // then that day's events. Row heights are fixed per kind so the total
    // is known up front — the popout is sized before it opens, which keeps
    // DankPopout's screen-edge clamping correct — and the offset of the
    // first day >= today is recorded so the list opens scrolled to it.
    function buildAgenda(events) {
        var rows = [];
        var height = 0;
        var todayOffset = -1;
        var today = new Date();
        var todayKey = dateKey(today);
        var tomorrowKey = dateKey(new Date(today.getTime() + 86400000));
        var lastDayKey = -1;
        var lastWeekKey = -1;
        for (var i = 0; i < events.length; i++) {
            var d = root.eventDate(events[i].start, events[i].allDay);
            var k = dateKey(d);
            if (k !== lastDayKey) {
                if (todayOffset < 0 && k >= todayKey)
                    todayOffset = height;

                var monday = new Date(d);
                monday.setDate(d.getDate() - ((d.getDay() + 6) % 7));
                var wk = dateKey(monday);
                if (lastWeekKey !== -1 && wk !== lastWeekKey) {
                    rows.push({
                        "kind": "week",
                        "label": "Week of " + root.formatLocalDate(monday, "d MMMM")
                    });
                    height += 30;
                }
                lastWeekKey = wk;
                var label = root.formatLocalDate(d, "dddd d MMMM");
                if (k === todayKey)
                    label = "Today · " + label;
                else if (k === tomorrowKey)
                    label = "Tomorrow · " + label;
                rows.push({
                    "kind": "day",
                    "label": label,
                    "isToday": k === todayKey
                });
                height += 34;
                lastDayKey = k;
            }
            rows.push({
                "kind": "event",
                "ev": events[i]
            });
            height += 54;
        }
        root.agendaContentHeight = height;
        // All events in the past: rest at the bottom (most recent).
        root.agendaTodayOffset = todayOffset < 0 ? height : todayOffset;
        return rows;
    }

    function eventTimeLabel(ev) {
        if (ev.allDay)
            return "All day";

        var label = Qt.formatTime(new Date(ev.start), "HH:mm");
        if (ev.end)
            label += "–" + Qt.formatTime(new Date(ev.end), "HH:mm");

        return label;
    }

    // "past" dims the row, "now" paints it green — both keyed off the same
    // countdownNow tick that drives the pill.
    function eventPhase(ev) {
        var startMs = root.eventDate(ev.start, ev.allDay).getTime();
        var endMs = ev.end ? root.eventDate(ev.end, ev.allDay).getTime() : startMs;
        if (root.countdownNow >= endMs)
            return "past";

        return root.countdownNow >= startMs ? "now" : "upcoming";
    }

    Process {
        id: fetchProcess

        command: ["bash", root.scriptPath, String(root.lookAheadDays), String(root.nowWindowMinutes)]
        running: false
        onExited: (exitCode, exitStatus) => {
            console.log("[dankCalendarAgenda] script exited:", exitCode, "summary:", root.eventSummary, "start:", root.eventStart);
            root.isLoading = false;
        }

        stdout: SplitParser {
            onRead: (data) => {
                return root.parseLine(data.trim());
            }
        }

        stderr: SplitParser {
            onRead: (data) => {
                return console.warn("[dankCalendarAgenda]", data);
            }
        }

    }

    Process {
        id: agendaProcess

        command: ["bash", root.agendaScriptPath, String(root.agendaPastDays), String(root.agendaFutureDays)]
        running: false
        onExited: (exitCode, exitStatus) => {
            root.agendaLoading = false;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                var events = [];
                try {
                    events = JSON.parse(text).events || [];
                } catch (e) {
                    console.warn("[dankCalendarAgenda] agenda parse failed:", e);
                }
                events.sort((a, b) => {
                    var dayA = root.dateKey(root.eventDate(a.start, a.allDay));
                    var dayB = root.dateKey(root.eventDate(b.start, b.allDay));
                    if (dayA !== dayB)
                        return dayA - dayB;

                    if ((a.allDay === true) !== (b.allDay === true))
                        return a.allDay ? -1 : 1;

                    return root.eventDate(a.start, a.allDay) - root.eventDate(b.start, b.allDay);
                });
                root.agendaEvents = events;
                root.agendaModel = root.buildAgenda(events);
            }
        }

        stderr: SplitParser {
            onRead: (data) => {
                return console.warn("[dankCalendarAgenda]", data);
            }
        }

    }

    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!fetchProcess.running)
                fetchProcess.running = true;

            if (!agendaProcess.running)
                agendaProcess.running = true;

        }
    }

    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.countdownNow = Date.now();
        }
    }

    function showEventTooltip(pill) {
        if (!root.showTooltip || !pill || !root.parentScreen)
            return ;

        var screen = root.parentScreen;
        var edge = root.axis?.edge ?? (root.isVertical ? "left" : "top");
        var gap = (root.barConfig?.spacing ?? 4) + Theme.spacingXS;
        var center = pill.mapToItem(null, pill.width / 2, pill.height / 2);
        var side, anchorX, anchorY;
        if (edge === "left") {
            side = "right";
            anchorX = root.barThickness + gap;
            anchorY = center.y;
        } else if (edge === "right") {
            side = "left";
            anchorX = screen.width - root.barThickness - gap;
            anchorY = center.y;
        } else if (edge === "bottom") {
            side = "top";
            anchorX = center.x;
            anchorY = screen.height - root.barThickness - gap;
        } else {
            side = "bottom";
            anchorX = center.x;
            anchorY = root.barThickness + gap;
        }
        // Stash the target so onLoaded can show it if the PanelWindow's Wayland
        // surface isn't ready synchronously on first activation.
        eventTooltipLoader.pendingX = anchorX;
        eventTooltipLoader.pendingY = anchorY;
        eventTooltipLoader.pendingScreen = screen;
        eventTooltipLoader.pendingSide = side;
        eventTooltipLoader.pendingShow = true;
        eventTooltipLoader.active = true;
        if (eventTooltipLoader.item)
            eventTooltipLoader.item.showAt(anchorX, anchorY, screen, side);
    }

    function hideEventTooltip() {
        eventTooltipLoader.pendingShow = false;
        if (eventTooltipLoader.item)
            eventTooltipLoader.item.hideTip();
        // Tear down the Wayland surface instead of leaving it hidden for the session.
        eventTooltipLoader.active = false;
    }

    Loader {
        id: eventTooltipLoader

        active: false

        property real pendingX: 0
        property real pendingY: 0
        property var pendingScreen: null
        property string pendingSide: "right"
        property bool pendingShow: false

        onLoaded: if (pendingShow)
            item.showAt(pendingX, pendingY, pendingScreen, pendingSide)

        sourceComponent: PanelWindow {
            id: ttip

            property real targetX: 0
            property real targetY: 0
            property string side: "right"

            function showAt(x, y, scr, placement) {
                ttip.screen = scr ?? null;
                targetX = x;
                targetY = y;
                side = placement;
                visible = true;
            }

            function hideTip() {
                visible = false;
            }

            WlrLayershell.namespace: "dms:plugins:dankcalendar-tooltip"
            WlrLayershell.layer: WlrLayershell.Overlay
            WlrLayershell.exclusiveZone: -1
            color: "transparent"
            visible: false
            implicitWidth: ttBg.implicitWidth
            implicitHeight: ttBg.implicitHeight
            // Empty input region: the tooltip is purely visual and never steals
            // clicks from the pill underneath it.
            mask: Region {
            }

            anchors {
                top: true
                left: true
            }

            margins {
                left: {
                    var sw = ttip.screen?.width ?? Screen.width;
                    var lx;
                    if (ttip.side === "right")
                        lx = ttip.targetX;
                    else if (ttip.side === "left")
                        lx = ttip.targetX - ttip.implicitWidth;
                    else
                        lx = ttip.targetX - ttip.implicitWidth / 2;
                    return Math.round(Math.max(Theme.spacingS, Math.min(sw - ttip.implicitWidth - Theme.spacingS, lx)));
                }
                top: {
                    var sh = ttip.screen?.height ?? Screen.height;
                    var ty;
                    if (ttip.side === "bottom")
                        ty = ttip.targetY;
                    else if (ttip.side === "top")
                        ty = ttip.targetY - ttip.implicitHeight;
                    else
                        ty = ttip.targetY - ttip.implicitHeight / 2;
                    return Math.round(Math.max(Theme.spacingS, Math.min(sh - ttip.implicitHeight - Theme.spacingS, ty)));
                }
            }

            Rectangle {
                id: ttBg

                implicitWidth: ttCol.width + Theme.spacingM * 2
                implicitHeight: ttCol.implicitHeight + Theme.spacingS * 2
                color: Theme.withAlpha(Theme.surfaceContainerHigh, root.barConfig?.transparency ?? 1)
                radius: Theme.cornerRadius
                border.width: 1
                border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.18)

                Column {
                    id: ttCol

                    x: Theme.spacingM
                    y: Theme.spacingS
                    // Scale with the theme font so the tooltip stays sensible
                    // across DPI / screen sizes instead of a fixed pixel width.
                    width: Math.round(Theme.fontSizeSmall * 18)
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: root.hasEvent ? root.eventSummary : "No events"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        width: parent.width
                        visible: root.hasEvent && root.timeText !== ""
                        text: root.isNow ? "Happening now" : ("Starts in " + root.timeText)
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.timeColor
                        wrapMode: Text.WordWrap
                    }

                }

            }

        }

    }

    popoutWidth: 440
    popoutHeight: 560
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Custom header (the built-in one hides with empty headerText):
            // the title itself opens DankCalendar, dankmail-style.
            Item {
                width: parent.width
                height: 48

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    StyledText {
                        text: "Dank Calendar"
                        font.pixelSize: Theme.fontSizeLarge + 2
                        font.weight: Font.Bold
                        color: titleHover.hovered ? Theme.primary : Theme.surfaceText
                    }

                    StyledText {
                        text: {
                            var date = root.formatLocalDate(new Date(), "dddd, d MMMM");
                            if (root.upcomingCount === 0)
                                return date;

                            return date + "  ·  " + root.upcomingCount + " upcoming";
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    HoverHandler {
                        id: titleHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: {
                            root.toggleDcal();
                            if (popout.closePopout)
                                popout.closePopout();

                        }
                    }

                }

                Row {
                    spacing: Theme.spacingXS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter

                    DankActionButton {
                        iconName: "add"
                        onClicked: {
                            root.newEvent();
                            if (popout.closePopout)
                                popout.closePopout();

                        }
                    }

                    DankActionButton {
                        iconName: "sync"
                        iconColor: root.agendaLoading ? Theme.primary : Theme.surfaceText
                        onClicked: root.refreshAll()
                    }

                    DankActionButton {
                        iconName: "close"
                        onClicked: {
                            if (popout.closePopout)
                                popout.closePopout();

                        }
                    }

                }

            }

            Item {
                width: parent.width
                // The list scrolls inside a fixed viewport when it grows
                // beyond the popout. agendaContentHeight is computed with
                // the model (fixed per-kind row heights), so the popout has
                // its final size before DankPopout positions it.
                readonly property real maxListHeight: 470

                implicitHeight: Math.max(40, Math.min(root.agendaContentHeight + Theme.spacingM * 2, maxListHeight))

                DankFlickable {
                    id: agendaFlick

                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    contentHeight: eventColumn.implicitHeight
                    clip: true

                    // Open the list scrolled to today, not to the oldest
                    // past day. DMS keeps popout contents warm after close,
                    // so reset on every open instead of relying only on
                    // Component.onCompleted. Once open, stop pinning as soon
                    // as the user scrolls in either direction.
                    property bool userScrolled: false
                    readonly property real todayY: Math.max(0, Math.min(root.agendaTodayOffset, contentHeight - height))

                    function pinToToday() {
                        if (!userScrolled)
                            contentY = todayY;

                    }

                    function resetToToday() {
                        userScrolled = false;
                        todayJumpAnim.stop();
                        pinToToday();
                        // The popout viewport can finish sizing one event-loop
                        // turn after the opened signal.
                        Qt.callLater(() => agendaFlick.pinToToday());
                    }

                    onMovementStarted: userScrolled = true
                    onTodayYChanged: pinToToday()
                    Component.onCompleted: resetToToday()

                    NumberAnimation {
                        id: todayJumpAnim

                        target: agendaFlick
                        property: "contentY"
                        duration: 250
                        easing.type: Easing.OutCubic
                    }

                    Column {
                        id: eventColumn

                        width: agendaFlick.width
                        spacing: 2

                        StyledText {
                            visible: root.agendaModel.length === 0
                            width: parent.width
                            text: root.agendaLoading ? "Loading events…" : "No events in this range."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: root.agendaModel

                            delegate: Item {
                                id: agendaRow

                                required property var modelData
                                readonly property string phase: modelData.kind === "event" ? root.eventPhase(modelData.ev) : ""

                                width: eventColumn.width
                                height: modelData.kind === "event" ? 52 : (modelData.kind === "day" ? 32 : 28)

                                // Week divider: small label + hairline.
                                Row {
                                    visible: agendaRow.modelData.kind === "week"
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    StyledText {
                                        id: weekLabel

                                        text: agendaRow.modelData.kind === "week" ? agendaRow.modelData.label : ""
                                        font.pixelSize: Math.max(9, Math.round(Theme.fontSizeSmall * 0.85))
                                        font.weight: Font.Medium
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Rectangle {
                                        width: parent.width - weekLabel.implicitWidth - Theme.spacingS * 2
                                        height: 1
                                        color: Theme.withAlpha(Theme.outline, 0.3)
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                }

                                // Day header: shaded band, today tinted primary.
                                Rectangle {
                                    visible: agendaRow.modelData.kind === "day"
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 26
                                    radius: Theme.cornerRadiusSmall
                                    color: agendaRow.modelData.isToday ? Theme.withAlpha(Theme.primary, 0.16) : Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: agendaRow.modelData.kind === "day" ? agendaRow.modelData.label : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: agendaRow.modelData.isToday ? Theme.primary : Theme.surfaceText
                                    }

                                }

                                // Event row: click opens the event's details
                                // window in DankCalendar.
                                Rectangle {
                                    id: eventRect

                                    visible: agendaRow.modelData.kind === "event"
                                    anchors.fill: parent
                                    radius: Theme.cornerRadiusSmall
                                    color: rowHover.hovered ? Theme.surfaceContainerHigh : "transparent"

                                    HoverHandler {
                                        id: rowHover

                                        enabled: eventRect.visible
                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    Row {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingS

                                        Rectangle {
                                            width: 4
                                            height: 34
                                            radius: 2
                                            color: agendaRow.phase === "now" ? "#66BB6A" : (agendaRow.phase === "past" ? Theme.surfaceVariantText : Theme.primary)
                                            opacity: agendaRow.phase === "past" ? 0.4 : 1
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Column {
                                            width: parent.width - 4 - Theme.spacingS * 2
                                            spacing: 1
                                            anchors.verticalCenter: parent.verticalCenter

                                            StyledText {
                                                width: parent.width
                                                text: agendaRow.modelData.kind === "event" ? (agendaRow.modelData.ev.summary || "(untitled)") : ""
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: agendaRow.phase === "past" ? Font.Normal : Font.Medium
                                                color: agendaRow.phase === "past" ? Theme.surfaceVariantText : Theme.surfaceText
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }

                                            StyledText {
                                                width: parent.width
                                                text: {
                                                    if (agendaRow.modelData.kind !== "event")
                                                        return "";

                                                    var ev = agendaRow.modelData.ev;
                                                    return root.eventTimeLabel(ev) + (agendaRow.phase === "now" ? "  ·  Now" : "") + (ev.location ? "  ·  " + ev.location : "");
                                                }
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: agendaRow.phase === "now" ? "#66BB6A" : Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }

                                        }

                                    }

                                    TapHandler {
                                        onTapped: {
                                            root.openEvent(agendaRow.modelData.ev);
                                            if (popout.closePopout)
                                                popout.closePopout();

                                        }
                                    }

                                }

                            }

                        }

                    }

                }

                Connections {
                    target: popout.parentPopout

                    function onOpened() {
                        agendaFlick.resetToToday();
                    }
                }

                // Floating "Today" chip: appears when the list is scrolled
                // away from today and jumps back to it.
                Rectangle {
                    visible: !todayJumpAnim.running && Math.abs(agendaFlick.contentY - agendaFlick.todayY) > 120
                    width: todayChipRow.implicitWidth + Theme.spacingM * 2
                    height: 28
                    radius: 14
                    color: Theme.primary
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.spacingM

                    Row {
                        id: todayChipRow

                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        DankIcon {
                            name: agendaFlick.contentY > agendaFlick.todayY ? "arrow_upward" : "arrow_downward"
                            size: Theme.iconSizeSmall
                            color: Theme.primaryText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Today"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primaryText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                    }

                    // MouseArea, not TapHandler: a default-policy TapHandler
                    // only takes a passive grab, so the tap would also fire
                    // the event row underneath (which opens DankCalendar).
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            todayJumpAnim.to = agendaFlick.todayY;
                            todayJumpAnim.restart();
                        }
                    }

                }

            }

        }

    }

    horizontalBarPill: Component {
        Item {
            id: hPill

            implicitWidth: hRow.implicitWidth
            implicitHeight: hRow.implicitHeight

            // Middle click on the pill: toggle DankCalendar directly (left
            // opens the popout, right refreshes). Only MiddleButton is
            // accepted, so left/right fall through to BasePill.
            MouseArea {
                anchors.fill: parent
                // Cover BasePill's padding too — middle clicks on the
                // capsule margin were falling through to the bar canvas.
                anchors.margins: -10
                acceptedButtons: Qt.MiddleButton
                onClicked: root.toggleDcal()
            }

            Row {
                id: hRow

                spacing: Theme.spacingXS

                DankIcon {
                    name: "calendar_today"
                    size: iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: summaryClip

                    width: root.dynamicWidth ? Math.min(summaryText.implicitWidth, root.pillMaxWidth) : root.pillMaxWidth
                    height: summaryText.implicitHeight
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter

                    property real overflow: Math.max(0, summaryText.implicitWidth - width)

                    StyledText {
                        id: summaryText

                        text: root.hasEvent ? root.eventSummary : "No events"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    SequentialAnimation {
                        running: summaryClip.overflow > 0
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) summaryText.x = 0

                        PauseAnimation { duration: 2000 }

                        NumberAnimation {
                            target: summaryText
                            property: "x"
                            to: -summaryClip.overflow
                            duration: summaryClip.overflow * 25
                            easing.type: Easing.Linear
                        }

                        PauseAnimation { duration: 1500 }

                        NumberAnimation {
                            target: summaryText
                            property: "x"
                            to: 0
                            duration: 300
                        }

                    }

                }

                StyledText {
                    text: "•"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.timeColor
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.hasEvent
                }

                StyledText {
                    text: root.timeText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.timeColor
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.hasEvent
                }

            }

            // Hover shows the full event in the same tooltip (handy when the
            // summary is mid-scroll). A HoverHandler is passive: unlike a
            // MouseArea it doesn't consume the hover, so the bar pill keeps its
            // own highlight + pointing-hand cursor and its popout click.
            HoverHandler {
                enabled: root.showTooltip
                onHoveredChanged: hovered ? root.showEventTooltip(hPill) : root.hideEventTooltip()
            }

        }

    }

    verticalBarPill: Component {
        Item {
            id: vPill

            implicitWidth: vCol.implicitWidth
            implicitHeight: vCol.implicitHeight

            // Middle click on the pill: toggle DankCalendar directly (left
            // opens the popout, right refreshes). Only MiddleButton is
            // accepted, so left/right fall through to BasePill.
            MouseArea {
                anchors.fill: parent
                // Cover BasePill's padding too — middle clicks on the
                // capsule margin were falling through to the bar canvas.
                anchors.margins: -10
                acceptedButtons: Qt.MiddleButton
                onClicked: root.toggleDcal()
            }

            Column {
                id: vCol

                spacing: Theme.spacingXS || 4

                DankIcon {
                    name: "calendar_today"
                    size: iconSize
                    color: Theme.primary
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                // Compact countdown so it fits a narrow vertical bar. The event
                // summary (which scrolls on the horizontal pill) is shown in a
                // hover tooltip instead.
                NumericText {
                    width: root.widgetThickness
                    text: root.compactTimeText
                    reserveText: "99d"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.timeColor
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.hasEvent
                }

            }

            // Hover shows the full event in a custom tooltip beside the bar.
            // HoverHandler is passive so the bar's own click still opens the
            // popout and the pill keeps its highlight + cursor.
            HoverHandler {
                enabled: root.showTooltip
                onHoveredChanged: hovered ? root.showEventTooltip(vPill) : root.hideEventTooltip()
            }

        }

    }

}
