// Test the actual QML JavaScript without opening links or requiring Qt.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync(path.join(__dirname, '../DankCalendarWidget.qml'), 'utf8');
const opened = [];
let tooltipHidden = 0;
const context = vm.createContext({
    hideEventTooltip() { tooltipHidden++; },
    Qt: { openUrlExternally: url => opened.push(url) },
});
for (const name of ['selectHighlightedEvent', 'meetingLink', 'joinMeeting']) {
    const fn = qml.match(new RegExp('    function ' + name + '\\([^]*?\\n    \\}'));
    assert.ok(fn, 'Missing QML function: ' + name);
    vm.runInContext(fn[0], context);
}
const now = Date.parse('2026-01-15T12:00:00Z');
const ev = (uid, start, end, extra = {}) => ({uid,
    start: new Date(now + start * 60000).toISOString(),
    end: new Date(now + end * 60000).toISOString(), ...extra});
const past = ev('past', -60, -1), active = ev('active', -5, 20), next = ev('next', 30, 60);
assert.equal(context.selectHighlightedEvent([next, past, active], now), active);
assert.equal(context.selectHighlightedEvent([past, next], now), next);
assert.equal(context.selectHighlightedEvent([past], now), null);
assert.equal(context.selectHighlightedEvent([], now), null);
assert.equal(context.selectHighlightedEvent([ev('day', -60, 60, {allDay:true}), next], now), next);
assert.equal(context.selectHighlightedEvent([ev('cancel', -5, 20, {status:'cancelled'}), next], now), next);
assert.equal(context.selectHighlightedEvent([ev('ended', -5, 0), next], now), next);
assert.equal(context.selectHighlightedEvent([active, ev('earlier', -10, 20)], now).uid, 'earlier');
assert.equal(context.selectHighlightedEvent([{uid:'invalid',start:'invalid'}, next], now), next);
context.joinMeeting(' https://example.com/meet/design?room=demo ');
assert.deepEqual(opened, ['https://example.com/meet/design?room=demo']);
assert.equal(tooltipHidden, 1);
for (const link of ['', null, 'javascript:alert(1)', 'file:///tmp/demo', 'https://example.com/a b']) {
    context.joinMeeting(link);
}
assert.equal(opened.length, 1);
assert.equal(tooltipHidden, 1);
console.log('Widget join/highlight tests: ok');
