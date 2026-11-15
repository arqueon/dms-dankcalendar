// Regression tests for calendarUtils.js — the shared helpers behind the bar
// width migration, agenda selection, scrolling and the copy action.
const assert = require('node:assert/strict');
const {library} = require('./qmljs.js');

const vmContext = library('calendarUtils.js');
// The vm has its own realm, so arrays come back with a foreign prototype:
// copy them before deep-comparing.
const U = Object.assign({}, vmContext, {
    eventIndices: (...args) => Array.from(vmContext.eventIndices(...args))
});

// --- 1. Settings migration: pillMaxWidth (title only) -> barContentWidth ---
// 1.4 sized only the title; the new budget also pays for icon, dot,
// countdown and Join, so the migrated default is the old value plus 100.
assert.equal(U.contentWidth({pillMaxWidth: 160}), 260, 'default 160 migrates to the 260 budget');
assert.equal(U.contentWidth({pillMaxWidth: 220}), 320);
assert.equal(U.contentWidth({}), 260, 'a fresh install lands on the same default');
assert.equal(U.contentWidth({barContentWidth: 300, pillMaxWidth: 160}), 300, 'the new key wins once written');
// A migrated 1.4 config could exceed the slider, and hand-edited pluginData
// can hold anything; the widget must stay inside the slider range.
assert.equal(U.contentWidth({pillMaxWidth: 600}), 600, 'clamped to the slider maximum');
assert.equal(U.contentWidth({barContentWidth: 40}), 120, 'clamped to the slider minimum');
assert.equal(U.contentWidth({barContentWidth: 5000}), 600);
assert.equal(U.contentWidth({barContentWidth: 'wide'}), 260, 'garbage falls back, it does not collapse the pill');
assert.equal(U.contentWidth({barContentWidth: null, pillMaxWidth: 200}), 300, 'null still reads the legacy key');

// --- 2. Bar display mode is validated, not trusted ---
for (const mode of ['full', 'countdownOnly', 'titleOnly'])
    assert.equal(U.displayMode(mode), mode);
for (const bogus of [undefined, null, '', 'FULL', 'titleonly', 0, {}])
    assert.equal(U.displayMode(bogus), 'full', 'unknown modes degrade to title + countdown');

// --- 3. Event identity survives a refresh ---
const ev = (o = {}) => Object.assign({calendarId: 'work', uid: 'u1', start: '2026-09-18T09:00:00Z'}, o);
assert.equal(U.eventKey(null), '');
assert.equal(U.eventKey(undefined), '');
assert.equal(U.eventKey(ev()), U.eventKey(ev()), 'a re-fetched copy of the same event keys the same');
assert.notEqual(U.eventKey(ev()), U.eventKey(ev({calendarId: 'personal'})), 'same uid on another calendar is another event');
assert.notEqual(U.eventKey(ev()), U.eventKey(ev({start: '2026-09-25T09:00:00Z'})), 'another occurrence of a recurring event is another row');
assert.notEqual(U.eventKey(ev()), U.eventKey(ev({uid: 'u2'})));
assert.equal(U.eventKey({id: 'fallback', start: 'x'}), U.eventKey({uid: 'fallback', start: 'x'}), 'id stands in when uid is absent');
// Distinct events must not collide through the separator between fields.
assert.notEqual(U.eventKey({calendarId: 'a', uid: 'b', start: 's'}), U.eventKey({calendarId: 'a', uid: 'b"', start: 's'}));

// --- 4. Selection walks events and skips headers ---
const evRow = e => ({kind: 'event', ev: e});
const model = [
    {kind: 'day', label: 'Yesterday'},        // offset 0
    evRow(ev({uid: 'past', start: '2026-09-17T09:00:00Z'})),   // 34
    {kind: 'week', label: 'Week of 14'},      // 88
    {kind: 'day', label: 'Today'},            // 118
    evRow(ev({uid: 'today-a', start: '2026-09-18T09:00:00Z'})), // 152
    evRow(ev({uid: 'today-b', start: '2026-09-18T15:00:00Z'})), // 206
    {kind: 'day', label: 'Tomorrow'},         // 260
    evRow(ev({uid: 'later', start: '2026-09-19T09:00:00Z'}))    // 294
];
const todayOffset = 118;
assert.deepEqual(U.eventIndices(model), [1, 4, 5, 7]);
assert.deepEqual(U.eventIndices([]), []);
assert.deepEqual(U.eventIndices([{kind: 'day'}, {kind: 'week'}]), [], 'a headers-only model has nothing to select');

// Opening with no selection lands on the first event at or after today.
assert.equal(U.selectionIndex(model, '', '', todayOffset), 4);
// A live key wins over the highlighted-event preference and over today.
assert.equal(U.selectionIndex(model, U.eventKey(model[7].ev), U.eventKey(model[4].ev), todayOffset), 7);
// The key is matched by value, so a refreshed model object still matches.
assert.equal(U.selectionIndex(model, U.eventKey(ev({uid: 'today-b', start: '2026-09-18T15:00:00Z'})), '', todayOffset), 5);
// Same uid, other calendar: identity must not fall through to the wrong row.
const twoCalendars = [
    evRow({calendarId: 'work', uid: 'standup', start: '2026-09-18T09:00:00Z'}),
    evRow({calendarId: 'personal', uid: 'standup', start: '2026-09-18T09:00:00Z'})
];
assert.equal(U.selectionIndex(twoCalendars, U.eventKey(twoCalendars[1].ev), '', 0), 1);
// Recurring: the occurrence start disambiguates.
const recurring = [
    evRow({calendarId: 'work', uid: 'weekly', start: '2026-09-18T09:00:00Z'}),
    evRow({calendarId: 'work', uid: 'weekly', start: '2026-09-25T09:00:00Z'})
];
assert.equal(U.selectionIndex(recurring, U.eventKey(recurring[1].ev), '', 0), 1);
// Selection gone from the model (deleted, or scrolled out of the window):
// fall back to the highlighted event, then to today.
assert.equal(U.selectionIndex(model, U.eventKey(ev({uid: 'deleted'})), U.eventKey(model[1].ev), todayOffset), 1);
assert.equal(U.selectionIndex(model, U.eventKey(ev({uid: 'deleted'})), U.eventKey(ev({uid: 'also-gone'})), todayOffset), 4);
// Nothing upcoming: rest on the last (most recent) event rather than nothing.
assert.equal(U.selectionIndex(model, '', '', 100000), 7);
assert.equal(U.selectionIndex([], '', '', 0), -1);
assert.equal(U.selectionIndex([{kind: 'day'}], '', '', 0), -1, 'an empty agenda selects nothing');

// --- 5. Keyboard stepping never lands on a header and never wraps ---
assert.equal(U.stepSelection(model, 4, 1), 5);
assert.equal(U.stepSelection(model, 5, 1), 7, 'the day header between them is skipped');
assert.equal(U.stepSelection(model, 4, -1), 1, 'week + day headers are skipped upwards');
assert.equal(U.stepSelection(model, 7, 1), 7, 'the last event holds instead of wrapping');
assert.equal(U.stepSelection(model, 1, -1), 1, 'the first event holds');
assert.equal(U.stepSelection(model, -1, 1), 1, 'no selection yet: down enters at the top');
assert.equal(U.stepSelection(model, -1, -1), 7, 'no selection yet: up enters at the bottom');
assert.equal(U.stepSelection(model, 3, 1), 1, 'a stale header index re-enters at the top');
assert.equal(U.stepSelection([], 0, 1), -1);
assert.equal(U.stepSelection([{kind: 'day'}], 0, 1), -1);

// --- 6. Row offsets match the fixed per-kind heights the popout is sized with ---
assert.equal(U.rowOffset(model, 0), 0);
assert.equal(U.rowOffset(model, 1), 34, 'day header');
assert.equal(U.rowOffset(model, 2), 88, 'day + event');
assert.equal(U.rowOffset(model, 4), 152, 'day + event + week + day');
assert.equal(U.rowOffset(model, 7), 294);
assert.equal(U.rowOffset(model, model.length), 348, 'the total equals the popout content height');

// --- 7. Scrolling keeps the selected row inside the viewport ---
const viewport = 200;
const content = 348;
assert.equal(U.visibleScroll(152, 54, 0, viewport, content), 6, 'a row below the fold scrolls just into view');
assert.equal(U.visibleScroll(34, 54, 100, viewport, content), 34, 'a row above the fold scrolls to its top');
assert.equal(U.visibleScroll(60, 54, 40, viewport, content), 40, 'an already visible row does not move the list');
assert.equal(U.visibleScroll(0, 54, 0, viewport, content), 0);
assert.equal(U.visibleScroll(294, 54, 0, viewport, content), 148, 'the last row stops at the end of the content');
assert.equal(U.visibleScroll(294, 54, 0, viewport, 300), 100, 'never scrolls past the content height');
assert.equal(U.visibleScroll(0, 54, 0, 500, content), 0, 'a viewport taller than the content never scrolls');
assert.equal(U.visibleScroll(-10, 54, 50, viewport, content), 0, 'never scrolls above the top');
// The invariant every keyboard step depends on: after the move, the row is
// fully inside the viewport for every event row in the model.
for (const index of U.eventIndices(model)) {
    for (const start of [0, 60, 148]) {
        const offset = U.rowOffset(model, index);
        const next = U.visibleScroll(offset, 54, start, viewport, content);
        assert.ok(next >= 0 && next <= content - viewport, 'scroll stays in range for row ' + index);
        assert.ok(offset >= next && offset + 54 <= next + viewport, 'row ' + index + ' is fully visible from ' + start);
    }
}

// --- 8. Copied text is readable, not a JSON dump ---
const copy = U.eventCopyText;
assert.equal(copy({summary: 'Design review', location: 'Room 3'}, 'Friday 18 September 2026', '09:00–10:00'),
    'Design review\nFriday 18 September 2026 · 09:00–10:00\nRoom 3');
assert.equal(copy({summary: 'Holiday'}, 'Friday 18 September 2026', 'All day'),
    'Holiday\nFriday 18 September 2026 · All day', 'an all-day event carries no clock time');
assert.equal(copy({summary: 'Ping', location: 'Online'}, '', ''), 'Ping\nOnline', 'no date, no empty line');
assert.equal(copy({location: 'Room 3'}, 'Friday 18 September 2026', ''), '(untitled)\nFriday 18 September 2026\nRoom 3');
assert.equal(copy({summary: ''}, '', ''), '(untitled)');
assert.equal(copy({summary: 42}, '', ''), '42', 'non-string fields are coerced, not concatenated as objects');
assert.equal(copy(null, 'Friday', '09:00'), '(untitled)\nFriday · 09:00', 'a missing event never throws');
assert.equal(copy({summary: 'A', location: ''}, 'D', 'T'), 'A\nD · T', 'an empty location adds no line');

console.log('calendarUtils tests: ok');
