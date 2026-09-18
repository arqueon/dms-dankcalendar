// The copy action: what lands on the clipboard, and how it is handed to
// `dms cl copy`. Runs in a negative UTC offset, where the all-day bug this
// plugin already fixed once would resurface as "yesterday".
process.env.TZ = 'America/Los_Angeles';
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {library, functions, freezeClock, Qt} = require('./qmljs.js');

const WIDGET = 'DankCalendarWidget.qml';
const commands = [];
const settings = {use24HourClock: true, padHours12Hour: false};
const context = vm.createContext({
    Qt,
    SettingsData: settings,
    CalendarUtils: library('calendarUtils.js'),
    Quickshell: {execDetached: command => commands.push(Array.from(command))}
});
context.root = context;
freezeClock(context, '2026-08-07T12:00:00-07:00');
functions(WIDGET, ['eventDate', 'formatLocalDate', 'formatTime', 'eventTimeLabel', 'copyEvent'], context);

const copy = ev => {
    commands.length = 0;
    context.copyEvent(ev);
    return commands.length ? commands[commands.length - 1] : null;
};
const text = ev => {
    const command = copy(ev);
    return command === null ? null : command[command.length - 1];
};

const meeting = {
    uid: 'm1',
    summary: 'Design review',
    location: 'Room 3',
    start: '2026-08-07T16:30:00-07:00',
    end: '2026-08-07T17:00:00-07:00'
};

// --- Clock format follows the DMS setting, not the locale ---
settings.use24HourClock = true;
assert.equal(text(meeting), 'Design review\nFriday 7 August 2026 · 16:30–17:00\nRoom 3');

settings.use24HourClock = false;
settings.padHours12Hour = false;
assert.equal(text(meeting), 'Design review\nFriday 7 August 2026 · 4:30 PM–5:00 PM\nRoom 3',
    '12-hour mode drops the leading zero unless DMS asks for it');

settings.padHours12Hour = true;
assert.equal(text(meeting), 'Design review\nFriday 7 August 2026 · 04:30 PM–05:00 PM\nRoom 3');
settings.use24HourClock = true;
settings.padHours12Hour = false;

// --- All-day events keep the calendar date in a negative UTC offset ---
// dcal serialises 8 August as UTC midnight; read with the local getters it
// would print "Friday 7 August" in PDT. The copy must say Saturday 8 August.
const holiday = {uid: 'h1', summary: 'Team offsite', allDay: true, start: '2026-08-08T00:00:00Z'};
assert.equal(text(holiday), 'Team offsite\nSaturday 8 August 2026 · All day');
assert.ok(!text(holiday).includes(':'), 'an all-day event carries no clock time at all');
// A multi-day all-day event still prints its own start date.
assert.equal(text({uid: 'h2', summary: 'Conference', allDay: true, start: '2026-08-10T00:00:00Z',
    end: '2026-08-12T00:00:00Z'}), 'Conference\nMonday 10 August 2026 · All day');

// --- Open-ended and degenerate events ---
assert.equal(text({uid: 'o1', summary: 'Focus', start: '2026-08-07T09:00:00-07:00'}),
    'Focus\nFriday 7 August 2026 · 09:00', 'an event without an end prints a single time');
assert.equal(text({uid: 'o2', start: '2026-08-07T09:00:00-07:00'}),
    '(untitled)\nFriday 7 August 2026 · 09:00');
assert.equal(copy(null), null, 'nothing selected copies nothing');
assert.equal(copy(undefined), null);

// --- Shape of the command ---
const command = copy(meeting);
assert.deepEqual(command.slice(0, 3), ['dms', 'cl', 'copy'], 'copies through the DMS clipboard, not xclip');
assert.equal(command.length, command.indexOf(command[command.length - 1]) + 1);
assert.ok(command.every(arg => typeof arg === 'string'), 'execDetached takes strings, not objects');
assert.equal(commands.length, 1, 'one copy per invocation');

// --- A title starting with "-" must not be read as a flag ---
// `dms clipboard copy` is a cobra command: "-d Retro" would be parsed as
// --download. The argument vector needs a "--" terminator before the text.
const dashed = {uid: 'd1', summary: '-d Retro planning', start: '2026-08-07T09:00:00-07:00'};
const dashedCommand = copy(dashed);
assert.ok(dashedCommand[dashedCommand.length - 1].startsWith('-d Retro'), 'the text is passed verbatim');
assert.ok(dashedCommand.includes('--'),
    'dms cl copy needs a "--" terminator so a title beginning with "-" is not parsed as a flag');
assert.equal(dashedCommand.indexOf('--'), dashedCommand.length - 2, '"--" comes immediately before the text');

console.log('Copy event tests: ok');
