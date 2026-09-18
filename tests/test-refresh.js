// Exercise the widget's refresh queue with independently delayed cache reads.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(path.join(__dirname, '../DankCalendarWidget.qml'), 'utf8');
const deferred = [];
const commands = [];
let timerRestarts = 0;
const context = vm.createContext({
    fetchProcess: { running: false, reloadPending: false },
    agendaProcess: { running: false, reloadPending: false },
    Qt: { callLater: fn => deferred.push(fn) },
    Quickshell: { execDetached: command => commands.push(Array.from(command)) },
    postSyncTimer: { restart: () => timerRestarts++ },
});
context.root = context;
for (const name of ['refreshAll', 'reloadEvents', 'queueFetch', 'finishFetch']) {
    const fn = qml.match(new RegExp('    function ' + name + '\\([^]*?\\n    \\}'));
    assert.ok(fn, 'Missing QML function: ' + name);
    vm.runInContext(fn[0], context);
}

context.refreshAll();
assert.deepEqual(commands, [['dcal', 'ipc', 'accounts.refresh']]);
assert.equal(timerRestarts, 1);
assert.equal(context.isLoading, true);
assert.equal(context.agendaLoading, true);
assert.equal(context.fetchProcess.running, true);
assert.equal(context.agendaProcess.running, true);

// The countdown finishes quickly, but the agenda is still running at 1.5s.
context.fetchProcess.running = false;
assert.equal(context.finishFetch(context.fetchProcess), false);
context.reloadEvents();
assert.equal(context.fetchProcess.running, true);
assert.equal(context.fetchProcess.reloadPending, false);
assert.equal(context.agendaProcess.reloadPending, true);
assert.equal(commands.length, 1, 'a cache reload must not start another network sync');

// Repeated requests coalesce into one follow-up for each busy process.
context.reloadEvents();
context.reloadEvents();
for (const process of [context.fetchProcess, context.agendaProcess]) {
    process.running = false;
    assert.equal(context.finishFetch(process), true);
    assert.equal(process.reloadPending, false);
    assert.equal(process.running, false, 'wait until the exit handler finishes');
}
assert.equal(deferred.length, 2);
while (deferred.length) deferred.shift()();
for (const process of [context.fetchProcess, context.agendaProcess]) {
    assert.equal(process.running, true);
    process.running = false;
    assert.equal(context.finishFetch(process), false, 'the queue must drain');
}
assert.equal(deferred.length, 0);
assert.equal(commands.length, 1);
console.log('Manual refresh queue tests: ok');
