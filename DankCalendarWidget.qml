import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "calendarUtils.js" as CalendarUtils
import "." as Local

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
    property string eventLocation: ""
    property string eventDescription: ""
    property string eventMeetingUrl: ""
    property string eventUrl: ""
    property bool isLoading: true
    property int refreshInterval: (pluginData.refreshInterval || 30) * 1000
    property int barContentWidth: CalendarUtils.contentWidth(pluginData)
    property string pillDisplayMode: CalendarUtils.displayMode(pluginData.pillDisplayMode)
    property bool scrollTitle: pluginData.scrollTitle ?? true
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
    property int selectedAgendaIndex: -1
    property string selectedEventKey: ""
    property var agendaPopout: null
    property bool agendaOpenRequested: false
    property real agendaOpenRequestedAt: 0
    // Prefer a timed event in progress; otherwise the next timed event.
    // All-day entries should not hide the next actual appointment.
    readonly property var highlightedEvent: selectHighlightedEvent(agendaEvents, countdownNow)

    Component.onCompleted: Local.AgendaController.registerRoot(root)
    Component.onDestruction: Local.AgendaController.unregisterRoot(root)

    function selectHighlightedEvent(events, now) {
        var active = null, next = null;
        for (var ev of events) {
            if (ev.allDay || ev.status === "cancelled")
                continue;
            var start = new Date(ev.start).getTime();
            var end = new Date(ev.end || ev.start).getTime();
            if (start <= now && now < end) {
                if (!active || start < new Date(active.start).getTime())
                    active = ev;
            } else if (start > now && (!next || start < new Date(next.start).getTime())) {
                next = ev;
            }
        }
        return active || next;
    }
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

    // Use conference links only, never the calendar event's detail-page URL.
    function meetingLink(value) {
        var link = String(value || "").trim();
        return /^https?:\/\/[^\s/]+(?:[/?#][^\s]*)?$/i.test(link) ? link : "";
    }

    function joinMeeting(link) {
        var url = meetingLink(link);
        if (url) {
            hideEventTooltip();
            Qt.openUrlExternally(url);
        }
    }

    component JoinButton: Rectangle {
        property bool compact: false
        property bool iconOnly: false
        signal clicked()
        implicitWidth: joinContent.implicitWidth + (compact ? 10 : 16)
        implicitHeight: compact ? 22 : 30
        radius: implicitHeight / 2
        color: joinMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.3) : Theme.withAlpha(Theme.primary, 0.16)
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, 0.4)
        Accessible.role: Accessible.Button
        Accessible.name: "Join Meeting"
        Accessible.onPressAction: clicked()

        Row {
            id: joinContent
            anchors.centerIn: parent
            spacing: Theme.spacingXS
            DankIcon {
                name: "videocam"
                size: 16
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                visible: !iconOnly
                text: compact ? "Join" : "Join Meeting"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: joinMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

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

    function applyEventPayload(payload) {
        eventSummary = payload.summary || "";
        eventStart = payload.start || "";
        eventEnd = payload.end || "";
        eventAllDay = payload.allDay === true;
        eventLocation = payload.location || "";
        eventDescription = payload.description || "";
        eventMeetingUrl = payload.meetingUrl || "";
        eventUrl = payload.url || "";
    }

    function formatEventSchedule() {
        if (!eventStart)
            return "";

        var start = eventDate(eventStart, eventAllDay);
        var day = formatLocalDate(start, "dddd d MMMM");
        if (eventAllDay)
            return day + " · All day";

        var schedule = day + " · " + root.formatTime(start);
        if (eventEnd)
            schedule += "–" + root.formatTime(eventDate(eventEnd, false));

        return schedule;
    }

    function toggleDcal() {
        Quickshell.execDetached(["dcal", "ipc", "ui.toggle", "view=day"]);
    }

    function openEvent(ev) {
        // events.list gives the occurrence start, which ui.openEvent needs
        // to resolve recurring events; for one-offs it matches and is inert.
        Quickshell.execDetached(["dcal", "ipc", "ui.openEvent", "uid=" + ev.uid, "start=" + ev.start]);
    }

    function selectedAgendaEvent() {
        if (selectedAgendaIndex < 0 || selectedAgendaIndex >= agendaModel.length)
            return null;

        var row = agendaModel[selectedAgendaIndex];
        return row.kind === "event" ? row.ev : null;
    }

    function syncAgendaSelection(preferredKey) {
        selectedAgendaIndex = CalendarUtils.selectionIndex(agendaModel, selectedEventKey, preferredKey || CalendarUtils.eventKey(highlightedEvent), agendaTodayOffset);
        var selected = selectedAgendaEvent();
        selectedEventKey = CalendarUtils.eventKey(selected);
    }

    function selectAgendaIndex(index) {
        if (index < 0 || index >= agendaModel.length || agendaModel[index].kind !== "event")
            return;

        selectedAgendaIndex = index;
        selectedEventKey = CalendarUtils.eventKey(agendaModel[index].ev);
    }

    function moveAgendaSelection(direction) {
        var next = CalendarUtils.stepSelection(agendaModel, selectedAgendaIndex, direction);
        if (next >= 0)
            selectAgendaIndex(next);
    }

    function selectAgendaToday() {
        selectedAgendaIndex = CalendarUtils.selectionIndex(agendaModel, "", "", agendaTodayOffset);
        selectedEventKey = CalendarUtils.eventKey(selectedAgendaEvent());
    }

    function copyEvent(ev) {
        if (!ev)
            return;

        var start = eventDate(ev.start, ev.allDay);
        var date = formatLocalDate(start, "dddd d MMMM yyyy");
        var time = ev.allDay ? "All day" : eventTimeLabel(ev);
        Quickshell.execDetached(["dms", "cl", "copy", "--", CalendarUtils.eventCopyText(ev, date, time)]);
    }

    function openSelectedAgendaEvent() {
        var ev = selectedAgendaEvent();
        if (!ev)
            return;

        openEvent(ev);
        if (agendaPopout?.close)
            agendaPopout.close();
    }

    function agendaIsOpen() {
        // A failed/deferred surface creation must not latch IPC open forever.
        if (agendaOpenRequested && Date.now() - agendaOpenRequestedAt >= 1500)
            agendaOpenRequested = false;
        return agendaOpenRequested || !!agendaPopout?.shouldBeVisible;
    }

    function openAgendaFromIpc() {
        if (agendaIsOpen())
            return "AGENDA_ALREADY_OPEN";

        agendaOpenRequested = true;
        agendaOpenRequestedAt = Date.now();
        triggerPopout();
        return "AGENDA_OPENING";
    }

    function closeAgendaFromIpc() {
        if (!agendaIsOpen())
            return "AGENDA_ALREADY_CLOSED";

        agendaOpenRequested = false;
        closePopout();
        return "AGENDA_CLOSED";
    }

    function toggleAgendaFromIpc() {
        return agendaIsOpen() ? closeAgendaFromIpc() : openAgendaFromIpc();
    }

    function refreshAgendaFromIpc() {
        refreshAll();
        return "AGENDA_REFRESH_QUEUED";
    }

    function agendaStatusFromIpc() {
        return agendaIsOpen() ? "AGENDA_OPEN" : "AGENDA_CLOSED";
    }

    function newEvent() {
        // ui.newEvent opens the editor directly (dcal > 0.2.2); older
        // daemons reject the unknown method, so fall back to day view,
        // where a click on a time slot creates an event.
        Quickshell.execDetached(["sh", "-c", "dcal ipc ui.newEvent || exec dcal ipc ui.show view=day"]);
    }

    function refreshAll() {
        Quickshell.execDetached(["dcal", "ipc", "accounts.refresh"]);
        reloadEvents();
        postSyncTimer.restart();
    }

    function reloadEvents() {
        root.isLoading = true;
        root.agendaLoading = true;
        queueFetch(fetchProcess);
        queueFetch(agendaProcess);
    }

    function queueFetch(process) {
        if (process.running)
            process.reloadPending = true;
        else
            process.running = true;
    }

    function finishFetch(process) {
        if (!process.reloadPending)
            return false;

        process.reloadPending = false;
        Qt.callLater(() => root.queueFetch(process));
        return true;
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

    function formatTime(time) {
        if (SettingsData.use24HourClock) {
            return Qt.formatTime(time, "HH:mm");
        } else if (SettingsData.padHours12Hour) {
            return Qt.formatTime(time, "hh:mm AP");
        } else {
            return Qt.formatTime(time, "h:mm AP");
        }
    }

    function eventTimeLabel(ev) {
        if (ev.allDay)
            return "All day";

        var label = root.formatTime(new Date(ev.start));
        if (ev.end)
            label += "–" + root.formatTime(new Date(ev.end));

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

        property bool reloadPending: false
        command: ["bash", root.scriptPath, String(root.lookAheadDays), String(root.nowWindowMinutes)]
        running: false
        onExited: (exitCode, exitStatus) => {
            console.log("[dankCalendarAgenda] script exited:", exitCode, "summary:", root.eventSummary, "start:", root.eventStart);
            root.isLoading = root.finishFetch(fetchProcess);
        }

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.applyEventPayload(JSON.parse(text));
                } catch (e) {
                    console.warn("[dankCalendarAgenda] next-event parse failed:", e);
                    root.applyEventPayload({});
                }
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

        property bool reloadPending: false
        command: ["bash", root.agendaScriptPath, String(root.agendaPastDays), String(root.agendaFutureDays)]
        running: false
        onExited: (exitCode, exitStatus) => {
            root.agendaLoading = root.finishFetch(agendaProcess);
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
                root.syncAgendaSelection(CalendarUtils.eventKey(root.highlightedEvent));
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
        id: postSyncTimer
        // accounts.refresh acknowledges scheduling, not completion. Polling
        // continues to pick up syncs that outlast this early cache reload.
        interval: 1500
        repeat: false
        onTriggered: root.reloadEvents()
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
                    width: Math.round(Theme.fontSizeSmall * 24)
                    spacing: Theme.spacingXS

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
                        visible: root.hasEvent && root.eventStart !== ""
                        text: root.formatEventSchedule()
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
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

                    Row {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: root.hasEvent && root.eventLocation !== ""

                        DankIcon {
                            name: "location_on"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            width: parent.width - Theme.iconSizeSmall - Theme.spacingXS
                            text: root.eventLocation
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: root.hasEvent && root.eventDescription !== ""
                        text: root.eventDescription
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: root.hasEvent && (root.eventMeetingUrl !== "" || root.eventUrl !== "")

                        DankIcon {
                            name: root.eventMeetingUrl !== "" ? "videocam" : "link"
                            size: Theme.iconSizeSmall
                            color: Theme.primary
                        }

                        StyledText {
                            text: root.eventMeetingUrl !== "" ? "Meeting link available" : "Event link available"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.primary
                        }
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

            focus: true

            function focusAgenda() {
                forceActiveFocus();
            }

            onParentPopoutChanged: {
                if (parentPopout)
                    root.agendaPopout = parentPopout;
            }

            Keys.onPressed: event => {
                var control = event.modifiers & Qt.ControlModifier;
                if (event.modifiers && !control)
                    return;
                if (control && event.key !== Qt.Key_R && event.key !== Qt.Key_C)
                    return;

                if (!control && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) {
                    root.moveAgendaSelection(1);
                } else if (!control && (event.key === Qt.Key_Up || event.key === Qt.Key_K)) {
                    root.moveAgendaSelection(-1);
                } else if (!control && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                    root.openSelectedAgendaEvent();
                } else if (!control && (event.key === Qt.Key_T || event.key === Qt.Key_Home)) {
                    root.selectAgendaToday();
                    agendaFlick.resetToToday();
                    agendaFlick.scrollSelectedIntoView();
                } else if (event.key === Qt.Key_R && control) {
                    if (!event.isAutoRepeat)
                        root.refreshAll();
                } else if (event.key === Qt.Key_C) {
                    root.copyEvent(root.selectedAgendaEvent());
                } else if (!control && event.key === Qt.Key_Escape) {
                    if (popout.closePopout)
                        popout.closePopout();
                } else {
                    return;
                }
                event.accepted = true;
            }

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
                        iconName: "content_copy"
                        visible: root.selectedAgendaEvent() !== null
                        onClicked: root.copyEvent(root.selectedAgendaEvent())
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

                    function scrollSelectedIntoView() {
                        if (root.selectedAgendaIndex < 0)
                            return;

                        var rowY = CalendarUtils.rowOffset(root.agendaModel, root.selectedAgendaIndex);
                        contentY = CalendarUtils.visibleScroll(rowY, 52, contentY, height, contentHeight);
                    }

                    onMovementStarted: userScrolled = true
                    onTodayYChanged: pinToToday()
                    onHeightChanged: scrollSelectedIntoView()
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
                                readonly property string meetingUrl: modelData.kind === "event" ? root.meetingLink(modelData.ev.meetingUrl) : ""
                                readonly property bool highlighted: modelData.kind === "event" && root.highlightedEvent !== null && modelData.ev.uid === root.highlightedEvent.uid && modelData.ev.start === root.highlightedEvent.start
                                readonly property bool selected: modelData.kind === "event" && CalendarUtils.eventKey(modelData.ev) === root.selectedEventKey

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
                                    color: agendaRow.selected ? Theme.withAlpha(Theme.primary, rowHover.hovered ? 0.30 : 0.22) : (agendaRow.highlighted ? Theme.withAlpha(Theme.primary, rowHover.hovered ? 0.24 : 0.14) : (rowHover.hovered ? Theme.surfaceContainerHigh : "transparent"))
                                    border.width: agendaRow.selected ? 2 : (agendaRow.highlighted ? 1 : 0)
                                    border.color: Theme.withAlpha(Theme.primary, agendaRow.selected ? 0.8 : 0.4)

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
                                            width: Math.max(0, parent.width - 4 - Theme.spacingS * 2 - (agendaJoin.visible ? agendaJoin.width + Theme.spacingS : 0))
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
                                                    return root.eventTimeLabel(ev) + (agendaRow.phase === "now" ? "  ·  Now" : (agendaRow.highlighted ? "  ·  Next" : "")) + (ev.location ? "  ·  " + ev.location : "");
                                                }
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: agendaRow.phase === "now" ? "#66BB6A" : Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }

                                        }

                                    }

                                    MouseArea {
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        width: parent.width - (agendaJoin.visible ? agendaJoin.width + Theme.spacingS * 2 : 0)
                                        onClicked: {
                                            root.selectAgendaIndex(index);
                                            root.openSelectedAgendaEvent();
                                        }
                                    }

                                    JoinButton {
                                        id: agendaJoin
                                        visible: agendaRow.meetingUrl !== ""
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        onClicked: {
                                            root.joinMeeting(agendaRow.meetingUrl);
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
                        root.agendaOpenRequested = false;
                        agendaFlick.resetToToday();
                        root.selectedEventKey = "";
                        root.syncAgendaSelection(CalendarUtils.eventKey(root.highlightedEvent));
                        Qt.callLater(() => {
                            popout.focusAgenda();
                            agendaFlick.scrollSelectedIntoView();
                        });
                    }
                }

                Connections {
                    target: root

                    function onSelectedAgendaIndexChanged() {
                        Qt.callLater(() => agendaFlick.scrollSelectedIntoView());
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

            readonly property bool showTitle: !root.hasEvent || root.pillDisplayMode !== "countdownOnly"
            readonly property bool showTime: root.hasEvent && root.pillDisplayMode !== "titleOnly"
            readonly property bool showDot: showTime && showTitle
            readonly property real controlsWidth: root.iconSize + (showTime ? hTime.implicitWidth + hRow.spacing : 0) + (showDot ? hDot.implicitWidth + hRow.spacing : 0) + (hJoin.visible ? hJoin.implicitWidth + hRow.spacing : 0)
            readonly property real minimumBudget: root.iconSize + hJoin.implicitWidth + hRow.spacing * 4 + (root.pillDisplayMode !== "titleOnly" ? timeMetrics.advanceWidth + hDot.implicitWidth : 0) + 24
            readonly property real budget: Math.max(root.barContentWidth, minimumBudget)
            implicitWidth: root.dynamicWidth ? Math.min(budget, controlsWidth + (showTitle ? summaryText.implicitWidth + hRow.spacing : 0)) : budget
            implicitHeight: hRow.implicitHeight

            TextMetrics {
                id: timeMetrics
                font: hTime.font
                text: "88d88h88m"
            }

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

                    visible: hPill.showTitle
                    width: Math.max(0, hPill.width - hPill.controlsWidth - hRow.spacing)
                    height: summaryText.implicitHeight
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter

                    property real overflow: Math.max(0, summaryText.implicitWidth - width)

                    StyledText {
                        id: summaryText

                        visible: hPill.showTitle
                        width: root.scrollTitle ? implicitWidth : summaryClip.width
                        text: root.hasEvent ? root.eventSummary : "No events"
                        textFormat: Text.PlainText
                        wrapMode: Text.NoWrap
                        maximumLineCount: 1
                        elide: root.scrollTitle ? Text.ElideNone : Text.ElideRight
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    SequentialAnimation {
                        running: root.scrollTitle && hPill.showTitle && hPill.visible && summaryClip.width > 0 && summaryClip.overflow > 0
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
                    id: hDot
                    text: "•"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.timeColor
                    anchors.verticalCenter: parent.verticalCenter
                    visible: hPill.showDot
                }

                StyledText {
                    id: hTime
                    text: root.timeText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root.timeColor
                    anchors.verticalCenter: parent.verticalCenter
                    visible: hPill.showTime
                }

                JoinButton {
                    id: hJoin
                    compact: true
                    visible: root.hasEvent && root.meetingLink(root.eventMeetingUrl) !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.joinMeeting(root.eventMeetingUrl)
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

                StyledText {
                    width: root.widgetThickness
                    text: root.hasEvent ? root.eventSummary : "—"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.pillDisplayMode !== "countdownOnly"
                }

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
                    visible: root.hasEvent && root.pillDisplayMode !== "titleOnly"
                }

                JoinButton {
                    compact: true
                    iconOnly: true
                    visible: root.hasEvent && root.meetingLink(root.eventMeetingUrl) !== ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: root.joinMeeting(root.eventMeetingUrl)
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
