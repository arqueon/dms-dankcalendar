// Agenda keyboard selection and scrolling, driven through the widget's own
// buildAgenda() so the rows, offsets and today marker are the real ones.
process.env.TZ = 'Europe/Madrid';
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {library, functions, handler, liveBinding, freezeClock, Qt, keyEvent} = require('./qmljs.js');

const WIDGET = 'DankCalendarWidget.qml';
const opened = [];
const copied = [];
const deferred = [];
const context = vm.createContext({
    Qt: Object.assign({}, Qt, {callLater: fn => deferred.push(fn)}),
    CalendarUtils: library('calendarUtils.js'),
    SettingsData: {use24HourClock: true, padHours12Hour: false},
    Quickshell: {execDetached: command => copied.push(Array.from(command))},
    agendaModel: [],
    agendaTodayOffset: 0,
    agendaContentHeight: 0,
    selectedAgendaIndex: -1,
    selectedEventKey: '',
    highlightedEvent: null,
    countdownNow: 0,
    agendaPopout: null,
    // The agenda Flickable's own scope: a short viewport so rows really fall
    // off the bottom and the scroll maths has to do something.
    contentY: 0,
    contentHeight: 0,
    height: 160
});
context.root = context;
context.popout = {closePopout: () => opened.push('closed')};
context.todayJumpAnim = {stop() {}, start() {}};
context.userScrolled = false;
freezeClock(context, '2026-09-18T10:00:00+02:00'); // Friday, local noon-ish

functions(WIDGET, ['dateKey', 'eventDate', 'formatLocalDate', 'buildAgenda', 'selectedAgendaEvent',
    'syncAgendaSelection', 'selectAgendaIndex', 'moveAgendaSelection', 'selectAgendaToday',
    'openEvent', 'openSelectedAgendaEvent', 'copyEvent', 'eventTimeLabel', 'formatTime',
    'refreshAll', 'reloadEvents', 'queueFetch'], context);
// The scroll helper lives inside the agenda Flickable, so it reads contentY,
// height and contentHeight from its own scope; the vm globals stand in.
functions(WIDGET, ['scrollSelectedIntoView', 'pinToToday', 'resetToToday'], context, 20);
// todayY is a binding on the Flickable; evaluate the real expression instead
// of guessing where "today" sits.
liveBinding(WIDGET, 'todayY', context);
// Keys.onPressed reaches the list through its id.
context.agendaFlick = {
    resetToToday: () => context.resetToToday(),
    pinToToday: () => context.pinToToday(),
    scrollSelectedIntoView: () => context.scrollSelectedIntoView()
};
// The keymap is a binding, not a function: extract the arrow and call it.
handler(WIDGET, 'Keys.onPressed', context, 12, 'pressHandler');
const press = (name, modifiers) => {
    const event = keyEvent(name, modifiers);
    context.pressHandler(event);
    return event;
};

const ev = (uid, start, extra = {}) => Object.assign({
    calendarId: 'work', uid, summary: uid, start, end: start
}, extra);
const load = events => {
    context.agendaModel = context.buildAgenda(events);
    return context.agendaModel;
};
const kinds = () => context.agendaModel.map(row => row.kind);
const selectedUid = () => (context.selectedAgendaEvent() || {}).uid || null;

// Thursday (past), Friday (today, three events), Monday (next week).
const base = [
    ev('yesterday', '2026-09-17T09:00:00+02:00'),
    ev('morning', '2026-09-18T09:00:00+02:00'),
    ev('lunch', '2026-09-18T13:00:00+02:00'),
    ev('evening', '2026-09-18T19:00:00+02:00'),
    ev('nextweek', '2026-09-21T09:00:00+02:00')
];
load(base);
assert.deepEqual(Array.from(kinds()), ['day', 'event', 'day', 'event', 'event', 'event', 'week', 'day', 'event'],
    'buildAgenda emits a week divider only when the week changes');

// --- Opening the popout ---
context.syncAgendaSelection('');
assert.equal(selectedUid(), 'morning', 'opens on the first event of today, not on yesterday');
assert.equal(context.selectedEventKey, context.CalendarUtils.eventKey(context.agendaModel[3].ev));

// --- Keyboard navigation skips headers and keeps identity ---
press('Down');
assert.equal(selectedUid(), 'lunch');
press('J');
assert.equal(selectedUid(), 'evening');
press('Down');
assert.equal(selectedUid(), 'nextweek', 'crosses the week divider and the day header in one step');
press('Down');
assert.equal(selectedUid(), 'nextweek', 'stops at the end instead of wrapping to yesterday');
press('K');
assert.equal(selectedUid(), 'evening');
for (let i = 0; i < 6; i++)
    press('Up');
assert.equal(selectedUid(), 'yesterday', 'walks back to the first row and holds');
assert.equal(context.agendaModel[context.selectedAgendaIndex].kind, 'event', 'never rests on a header');

// A header index can never be selected directly (a click on a divider).
context.selectAgendaIndex(0);
assert.equal(selectedUid(), 'yesterday', 'clicking a day header leaves the selection alone');
context.selectAgendaIndex(999);
assert.equal(selectedUid(), 'yesterday');

// --- t / Home returns to today ---
press('T');
assert.equal(selectedUid(), 'morning');
context.selectAgendaIndex(8);
press('Home');
assert.equal(selectedUid(), 'morning');

// --- Identity survives a refresh that renumbers the rows ---
context.selectAgendaIndex(4); // "lunch"
assert.equal(selectedUid(), 'lunch');
const beforeIndex = context.selectedAgendaIndex;
// The daemon returns fresh objects, an event is added earlier in the day and
// one is dropped: index changes, the selected event must not.
load([
    ev('yesterday', '2026-09-17T09:00:00+02:00'),
    ev('earlybird', '2026-09-18T07:30:00+02:00'),
    ev('morning', '2026-09-18T09:00:00+02:00'),
    ev('lunch', '2026-09-18T13:00:00+02:00'),
    ev('nextweek', '2026-09-21T09:00:00+02:00')
]);
context.syncAgendaSelection('');
assert.equal(selectedUid(), 'lunch', 'the selection follows the event, not the row number');
assert.notEqual(context.selectedAgendaIndex, beforeIndex, 'and the row number really did change');

// Same uid on two calendars: the selection must stay on the right one.
load([
    ev('standup', '2026-09-18T09:00:00+02:00', {calendarId: 'work'}),
    ev('standup', '2026-09-18T09:00:00+02:00', {calendarId: 'personal'})
]);
context.selectAgendaIndex(2); // the personal copy
assert.equal(context.selectedAgendaEvent().calendarId, 'personal');
load([
    ev('standup', '2026-09-18T09:00:00+02:00', {calendarId: 'work'}),
    ev('standup', '2026-09-18T09:00:00+02:00', {calendarId: 'personal'})
]);
context.syncAgendaSelection('');
assert.equal(context.selectedAgendaEvent().calendarId, 'personal', 'calendar id is part of the identity');

// Recurring occurrences share a uid; the occurrence start separates them.
load([
    ev('weekly', '2026-09-18T09:00:00+02:00'),
    ev('weekly', '2026-09-25T09:00:00+02:00')
]);
context.selectAgendaIndex(context.CalendarUtils.eventIndices(context.agendaModel)[1]);
assert.equal(context.selectedAgendaEvent().start, '2026-09-25T09:00:00+02:00');
load([
    ev('weekly', '2026-09-18T09:00:00+02:00'),
    ev('weekly', '2026-09-25T09:00:00+02:00'),
    ev('weekly', '2026-10-02T09:00:00+02:00')
]);
context.syncAgendaSelection('');
assert.equal(context.selectedAgendaEvent().start, '2026-09-25T09:00:00+02:00', 'stays on the same occurrence');

// The selected event disappears: fall back to the highlighted one, then today.
load(base);
context.selectAgendaIndex(1); // yesterday
context.highlightedEvent = base[3]; // "evening"
load([base[0], base[1], base[4]]);
context.selectedEventKey = context.CalendarUtils.eventKey({calendarId: 'work', uid: 'gone', start: 'x'});
context.syncAgendaSelection('');
assert.equal(selectedUid(), 'morning', 'a vanished selection and an absent highlight fall back to today');
context.highlightedEvent = null;

// --- Scrolling: every keyboard step leaves the row visible ---
load(base);
context.syncAgendaSelection('');
context.contentHeight = context.agendaContentHeight;
context.contentY = 0;
// A row delegate is 52 tall; the extra 2 in rowOffset() is the column
// spacing between rows, so visibility is judged against the delegate.
const ROW = 52;
const visible = () => {
    const offset = context.CalendarUtils.rowOffset(context.agendaModel, context.selectedAgendaIndex);
    return offset >= context.contentY - 0.5 && offset + ROW <= context.contentY + context.height + 0.5;
};
for (const key of ['Down', 'Down', 'Down', 'Down', 'Up', 'Up', 'Home']) {
    press(key);
    context.scrollSelectedIntoView();
    assert.ok(context.contentY >= 0, 'never scrolls above the top');
    assert.ok(context.contentY <= Math.max(0, context.contentHeight - context.height), 'never scrolls past the end');
    assert.ok(visible(), 'row ' + context.selectedAgendaIndex + ' stays visible after ' + key);
}
// A viewport taller than the agenda never scrolls at all.
context.height = 1000;
context.contentY = 0;
context.scrollSelectedIntoView();
assert.equal(context.contentY, 0);
// Nothing selected: the scroll helper is inert.
context.height = 160;
context.contentY = 42;
context.selectedAgendaIndex = -1;
context.scrollSelectedIntoView();
assert.equal(context.contentY, 42, 'no selection, no scrolling');

// --- Enter opens the selected event; unknown keys are not swallowed ---
load(base);
context.syncAgendaSelection('');
const before = opened.length;
press('Return');
assert.equal(copied.length + opened.length > before, true);
const openCommand = copied[copied.length - 1];
assert.deepEqual(Array.from(openCommand.slice(0, 3)), ['dcal', 'ipc', 'ui.openEvent'],
    'Enter opens the event through dcal IPC');
assert.ok(openCommand.some(arg => arg.startsWith('start=')), 'the occurrence start is passed for recurring events');
assert.equal(press('Down').accepted, true, 'handled keys are accepted');
assert.equal(press('Tab').accepted, false, 'unhandled keys fall through to the rest of the popout');
assert.equal(press('R').accepted, false, 'a bare r is not the refresh shortcut');

let refreshes = 0;
context.refreshAll = () => refreshes++;
assert.equal(press('R', Qt.ControlModifier).accepted, true);
assert.equal(refreshes, 1);
const repeatedRefresh = keyEvent('R', Qt.ControlModifier);
repeatedRefresh.isAutoRepeat = true;
context.pressHandler(repeatedRefresh);
assert.equal(repeatedRefresh.accepted, true);
assert.equal(refreshes, 1, 'holding Ctrl+R must not issue repeated network syncs');

// An empty agenda must not throw on any key.
load([]);
context.syncAgendaSelection('');
assert.equal(context.selectedAgendaIndex, -1);
assert.equal(context.selectedAgendaEvent(), null);
for (const key of ['Down', 'Up', 'Return', 'Home', 'T', 'C'])
    press(key);
assert.equal(context.selectedAgendaEvent(), null, 'an empty agenda stays empty');

console.log('Agenda selection tests: ok');
