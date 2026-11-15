// The same helpers the Node tests cover, run inside a real Qt QML engine.
//
// Node and QtQuick's JS engines are not the same: a `.pragma library` file
// that parses in Node can still fail to load in the shell (optional chaining,
// nullish coalescing, for-of over a QML list). This suite is the cheap way to
// find that out without restarting DMS.
import QtQuick
import QtTest
import "../../calendarUtils.js" as CalendarUtils

TestCase {
    id: suite
    name: "CalendarUtils"

    function eventRow(uid, start, calendarId) {
        return {kind: "event", ev: {calendarId: calendarId || "work", uid: uid, start: start}};
    }

    readonly property var model: [
        {kind: "day", label: "Thursday"},
        eventRow("yesterday", "2026-09-17T09:00:00Z"),
        {kind: "week", label: "Week of 14 September"},
        {kind: "day", label: "Today"},
        eventRow("morning", "2026-09-18T09:00:00Z"),
        eventRow("lunch", "2026-09-18T13:00:00Z")
    ]

    function test_library_loads() {
        // A load failure here shows up as an undefined function, which is
        // exactly the failure mode a Node-only suite cannot see.
        verify(typeof CalendarUtils.contentWidth === "function");
        verify(typeof CalendarUtils.eventCopyText === "function");
        verify(typeof CalendarUtils.selectionIndex === "function");
    }

    function test_settings_migration() {
        compare(CalendarUtils.contentWidth({pillMaxWidth: 160}), 260);
        compare(CalendarUtils.contentWidth({barContentWidth: 320}), 320);
        compare(CalendarUtils.contentWidth({}), 260);
        compare(CalendarUtils.contentWidth({barContentWidth: 40}), 120);
        compare(CalendarUtils.contentWidth({barContentWidth: 5000}), 600);
    }

    function test_display_mode() {
        compare(CalendarUtils.displayMode("titleOnly"), "titleOnly");
        compare(CalendarUtils.displayMode("countdownOnly"), "countdownOnly");
        compare(CalendarUtils.displayMode(undefined), "full");
        compare(CalendarUtils.displayMode("nonsense"), "full");
    }

    function test_event_identity() {
        var a = {calendarId: "work", uid: "u1", start: "2026-09-18T09:00:00Z"};
        var b = {calendarId: "personal", uid: "u1", start: "2026-09-18T09:00:00Z"};
        var c = {calendarId: "work", uid: "u1", start: "2026-09-25T09:00:00Z"};
        compare(CalendarUtils.eventKey(a), CalendarUtils.eventKey({calendarId: "work", uid: "u1", start: "2026-09-18T09:00:00Z"}));
        verify(CalendarUtils.eventKey(a) !== CalendarUtils.eventKey(b));
        verify(CalendarUtils.eventKey(a) !== CalendarUtils.eventKey(c));
        compare(CalendarUtils.eventKey(null), "");
    }

    // for-of over the index array is the construct most likely to behave
    // differently between engines.
    function test_selection_skips_headers() {
        compare(CalendarUtils.eventIndices(suite.model).length, 3);
        compare(CalendarUtils.selectionIndex(suite.model, "", "", 118), 4);
        compare(CalendarUtils.selectionIndex(suite.model, CalendarUtils.eventKey(suite.model[5].ev), "", 118), 5);
        compare(CalendarUtils.selectionIndex(suite.model, "gone", CalendarUtils.eventKey(suite.model[1].ev), 118), 1);
        compare(CalendarUtils.selectionIndex([], "", "", 0), -1);
        compare(CalendarUtils.stepSelection(suite.model, 4, 1), 5);
        compare(CalendarUtils.stepSelection(suite.model, 1, 1), 4);
        compare(CalendarUtils.stepSelection(suite.model, 5, 1), 5);
        compare(CalendarUtils.stepSelection(suite.model, -1, -1), 5);
    }

    function test_row_offsets_and_scroll() {
        compare(CalendarUtils.rowOffset(suite.model, 1), 34);
        compare(CalendarUtils.rowOffset(suite.model, 4), 152);
        compare(CalendarUtils.visibleScroll(152, 52, 0, 160, 260), 44);
        compare(CalendarUtils.visibleScroll(34, 52, 100, 160, 260), 34);
        compare(CalendarUtils.visibleScroll(0, 52, 0, 400, 260), 0);
    }

    // Optional chaining inside eventCopyText(): if the engine rejected it the
    // whole library would fail to load, so this doubles as a syntax check.
    function test_copy_text() {
        compare(CalendarUtils.eventCopyText({summary: "Design review", location: "Room 3"},
            "Friday 18 September 2026", "09:00–10:00"),
            "Design review\nFriday 18 September 2026 · 09:00–10:00\nRoom 3");
        compare(CalendarUtils.eventCopyText({summary: "Holiday"}, "Friday 18 September 2026", "All day"),
            "Holiday\nFriday 18 September 2026 · All day");
        compare(CalendarUtils.eventCopyText(null, "", ""), "(untitled)");
    }
}
