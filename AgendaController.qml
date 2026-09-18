pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// One controller and IpcHandler live in the QML engine, regardless of how
// many bars render this widget. Roots register themselves so an IPC request
// always affects only the widget on the focused monitor.
QtObject {
    id: root

    property var liveRoots: []

    function registerRoot(widget) {
        if (!widget || liveRoots.indexOf(widget) >= 0)
            return;

        liveRoots = liveRoots.concat([widget]);
    }

    function unregisterRoot(widget) {
        var index = liveRoots.indexOf(widget);
        if (index < 0)
            return;

        var next = liveRoots.slice();
        next.splice(index, 1);
        liveRoots = next;
    }

    function screenName(widget) {
        return widget?.parentScreen?.name || "";
    }

    function focusedRoot() {
        var focusedScreen = BarWidgetService.getFocusedScreenName();
        if (focusedScreen) {
            for (var i = 0; i < liveRoots.length; i++) {
                if (screenName(liveRoots[i]) === focusedScreen)
                    return liveRoots[i];
            }
        }
        return liveRoots.length ? liveRoots[0] : null;
    }

    property IpcHandler ipcHandler: IpcHandler {
        target: "dankCalendarAgenda"

        function open(): string {
            var widget = root.focusedRoot();
            return widget ? widget.openAgendaFromIpc() : "AGENDA_UNAVAILABLE";
        }

        function close(): string {
            var widget = root.focusedRoot();
            return widget ? widget.closeAgendaFromIpc() : "AGENDA_UNAVAILABLE";
        }

        function toggle(): string {
            var widget = root.focusedRoot();
            return widget ? widget.toggleAgendaFromIpc() : "AGENDA_UNAVAILABLE";
        }

        function refresh(): string {
            var widget = root.focusedRoot();
            return widget ? widget.refreshAgendaFromIpc() : "AGENDA_UNAVAILABLE";
        }

        function status(): string {
            var widget = root.focusedRoot();
            return widget ? widget.agendaStatusFromIpc() : "AGENDA_UNAVAILABLE";
        }
    }
}
