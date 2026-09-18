// IPC control of the agenda: one AgendaController routes every request to a
// single widget on the focused monitor. Open/close are idempotent; each
// explicit refresh invokes exactly one sync.
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {library, functions, Qt} = require('./qmljs.js');

const WIDGET = 'DankCalendarWidget.qml';
const CONTROLLER = 'AgendaController.qml';

// --- A widget instance: the real IPC entry points over stub popout state ---
function makeWidget(screen) {
    const calls = [];
    const syncs = [];
    const deferred = [];
    const context = vm.createContext({
        Qt: Object.assign({}, Qt, {callLater: fn => deferred.push(fn)}),
        CalendarUtils: library('calendarUtils.js'),
        Quickshell: {execDetached: command => syncs.push(Array.from(command))},
        postSyncTimer: {restart() {}},
        fetchProcess: {running: false, reloadPending: false},
        agendaProcess: {running: false, reloadPending: false},
        agendaOpenRequested: false,
        agendaOpenRequestedAt: 0,
        agendaPopout: {shouldBeVisible: false},
        isLoading: false,
        agendaLoading: false
    });
    context.root = context;
    context.triggerPopout = () => {
        calls.push('open');
        context.agendaPopout.shouldBeVisible = true;
    };
    context.closePopout = () => {
        calls.push('close');
        context.agendaPopout.shouldBeVisible = false;
    };
    functions(WIDGET, ['agendaIsOpen', 'openAgendaFromIpc', 'closeAgendaFromIpc', 'toggleAgendaFromIpc',
        'refreshAgendaFromIpc', 'agendaStatusFromIpc', 'refreshAll', 'reloadEvents', 'queueFetch',
        'finishFetch'], context);
    // The popout's own opened handler, which clears the in-flight flag.
    context.agendaFlick = {resetToToday() {}, scrollSelectedIntoView() {}};
    context.popout = {focusAgenda() {}, parentPopout: null};
    context.syncAgendaSelection = () => {};
    context.selectedEventKey = '';
    context.highlightedEvent = null;
    functions(WIDGET, ['onOpened'], context, 20);
    return {
        parentScreen: {name: screen},
        calls,
        syncs,
        context,
        deferred,
        // What DankPopout does once the surface is actually on screen.
        popoutOpened: () => {
            context.onOpened();
            while (deferred.length) deferred.shift()();
        },
        openAgendaFromIpc: () => context.openAgendaFromIpc(),
        closeAgendaFromIpc: () => context.closeAgendaFromIpc(),
        toggleAgendaFromIpc: () => context.toggleAgendaFromIpc(),
        refreshAgendaFromIpc: () => context.refreshAgendaFromIpc(),
        agendaStatusFromIpc: () => context.agendaStatusFromIpc()
    };
}

// --- The controller, plus the IpcHandler methods DMS exposes ---
let focusedScreen = '';
const controller = vm.createContext({
    Qt,
    BarWidgetService: {getFocusedScreenName: () => focusedScreen},
    liveRoots: []
});
controller.root = controller;
functions(CONTROLLER, ['registerRoot', 'unregisterRoot', 'screenName', 'focusedRoot'], controller);
// The IPC methods live inside the IpcHandler block, one level deeper.
functions(CONTROLLER, ['open', 'close', 'toggle', 'refresh', 'status'], controller, 8);

const left = makeWidget('DP-1');
const right = makeWidget('HDMI-A-1');

// --- Registration ---
assert.equal(controller.focusedRoot(), null, 'no bars yet: IPC has nothing to talk to');
assert.equal(controller.open(), 'AGENDA_UNAVAILABLE', 'and says so instead of throwing');
controller.registerRoot(left);
controller.registerRoot(right);
assert.equal(controller.liveRoots.length, 2);
controller.registerRoot(left);
assert.equal(controller.liveRoots.length, 2, 'a re-registered bar is not counted twice');
controller.registerRoot(null);
controller.registerRoot(undefined);
assert.equal(controller.liveRoots.length, 2, 'a null root is ignored');

// --- Routing: exactly the widget on the focused monitor ---
focusedScreen = 'HDMI-A-1';
assert.equal(controller.focusedRoot(), right);
assert.equal(controller.open(), 'AGENDA_OPENING');
assert.deepEqual(right.calls, ['open']);
assert.deepEqual(left.calls, [], 'the bar on the other monitor is untouched');
assert.equal(left.agendaStatusFromIpc(), 'AGENDA_CLOSED');
assert.equal(right.agendaStatusFromIpc(), 'AGENDA_OPEN');

focusedScreen = 'DP-1';
assert.equal(controller.open(), 'AGENDA_OPENING');
assert.deepEqual(left.calls, ['open'], 'following the focus moves the agenda, it does not clone it');
assert.equal(right.calls.length, 1);

// Unknown or empty focused screen: fall back to one bar, never to all of them.
focusedScreen = 'DP-9';
assert.equal(controller.focusedRoot(), left, 'an unknown monitor falls back to the first bar');
focusedScreen = '';
assert.equal(controller.focusedRoot(), left, 'no focus information falls back to the first bar');
// A bar without a screen must not swallow requests meant for a named one.
const headless = makeWidget(undefined);
controller.registerRoot(headless);
focusedScreen = 'HDMI-A-1';
assert.equal(controller.focusedRoot(), right);
assert.equal(controller.screenName(headless), '');
assert.equal(controller.screenName(null), '');
controller.unregisterRoot(headless);

// --- Idempotent open/close ---
focusedScreen = 'DP-1';
left.calls.length = 0;
assert.equal(left.context.agendaPopout.shouldBeVisible, true, 'already open from the request above');
assert.equal(controller.open(), 'AGENDA_ALREADY_OPEN');
assert.equal(controller.open(), 'AGENDA_ALREADY_OPEN');
assert.deepEqual(left.calls, [], 'repeating open does not re-trigger the popout');
assert.equal(controller.close(), 'AGENDA_CLOSED');
assert.equal(controller.close(), 'AGENDA_ALREADY_CLOSED');
assert.equal(controller.close(), 'AGENDA_ALREADY_CLOSED');
assert.deepEqual(left.calls, ['close'], 'repeating close does not re-trigger the popout');
assert.equal(controller.status(), 'AGENDA_CLOSED');

// The popout can also be opened by the user's mouse: IPC must see that state.
left.context.agendaPopout.shouldBeVisible = true;
assert.equal(controller.status(), 'AGENDA_OPEN', 'a popout opened by click counts as open');
assert.equal(controller.open(), 'AGENDA_ALREADY_OPEN');
left.calls.length = 0;
assert.equal(controller.close(), 'AGENDA_CLOSED', 'and IPC can close it');
assert.deepEqual(left.calls, ['close']);

// --- The in-flight flag clears once the popout is really open ---
// Otherwise a popout the user closes with a click outside could never be
// reopened over IPC: the widget would keep answering AGENDA_ALREADY_OPEN.
focusedScreen = 'DP-1';
left.context.agendaPopout.shouldBeVisible = false;
left.context.agendaOpenRequested = false;
left.calls.length = 0;
assert.equal(controller.open(), 'AGENDA_OPENING');
assert.equal(left.context.agendaOpenRequested, true, 'the request is in flight');
left.popoutOpened();
assert.equal(left.context.agendaOpenRequested, false, 'and is cleared when the popout opens');
assert.equal(controller.status(), 'AGENDA_OPEN', 'the popout itself now reports the state');
// The user closes it by clicking elsewhere; IPC must be able to open it again.
left.context.agendaPopout.shouldBeVisible = false;
assert.equal(controller.status(), 'AGENDA_CLOSED');
left.calls.length = 0;
assert.equal(controller.open(), 'AGENDA_OPENING', 'a click-closed popout reopens over IPC');
assert.deepEqual(left.calls, ['open']);
left.popoutOpened();
controller.close();

// Surface creation can fail: pending open must expire so another attempt works.
const failedOpen = makeWidget('missing-surface');
let now = 10000;
failedOpen.context.Date = {now: () => now};
failedOpen.context.triggerPopout = () => failedOpen.calls.push('open');
assert.equal(failedOpen.openAgendaFromIpc(), 'AGENDA_OPENING');
now += 100;
assert.equal(failedOpen.openAgendaFromIpc(), 'AGENDA_ALREADY_OPEN');
now += 1500;
assert.equal(failedOpen.agendaStatusFromIpc(), 'AGENDA_CLOSED');
assert.equal(failedOpen.openAgendaFromIpc(), 'AGENDA_OPENING');
assert.deepEqual(failedOpen.calls, ['open', 'open']);
failedOpen.closeAgendaFromIpc();

// --- Toggle alternates, one action per invocation ---
left.calls.length = 0;
assert.equal(controller.toggle(), 'AGENDA_OPENING');
assert.equal(controller.toggle(), 'AGENDA_CLOSED');
assert.equal(controller.toggle(), 'AGENDA_OPENING');
assert.deepEqual(left.calls, ['open', 'close', 'open'], 'one popout action per toggle, never two');
controller.close();

// --- Refresh runs exactly one provider sync ---
left.syncs.length = 0;
assert.equal(controller.refresh(), 'AGENDA_REFRESH_QUEUED');
assert.deepEqual(left.syncs, [['dcal', 'ipc', 'accounts.refresh']], 'one network sync per refresh');
assert.equal(left.context.fetchProcess.running, true);
assert.equal(left.context.agendaProcess.running, true);
assert.deepEqual(right.syncs, [], 'only the focused bar syncs');
assert.equal(controller.refresh(), 'AGENDA_REFRESH_QUEUED');
// IPC refresh is an explicit request; Niri examples disable key repeat.
assert.equal(left.syncs.length, 2, 'each IPC refresh triggers its own provider sync');
left.context.fetchProcess.running = false;
left.context.agendaProcess.running = false;

// --- Unregistering a bar (monitor unplugged) ---
controller.unregisterRoot(left);
assert.equal(controller.liveRoots.length, 1);
focusedScreen = 'DP-1';
assert.equal(controller.focusedRoot(), right, 'a removed bar never receives IPC again');
controller.unregisterRoot(left);
assert.equal(controller.liveRoots.length, 1, 'unregistering twice is harmless');
controller.unregisterRoot(right);
assert.equal(controller.liveRoots.length, 0);
assert.equal(controller.toggle(), 'AGENDA_UNAVAILABLE');
assert.equal(controller.refresh(), 'AGENDA_UNAVAILABLE');
assert.equal(controller.status(), 'AGENDA_UNAVAILABLE');

console.log('Agenda IPC tests: ok');
