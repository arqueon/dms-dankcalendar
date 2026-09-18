// Shared loader: the tests run the shipped QML/JS, never a copy of it.
//
// The widget is QML, so its logic cannot be require()d. Every helper here
// pulls the real source out of the real file and evaluates it in a Node vm
// with the QML globals (Qt, Quickshell, SettingsData, CalendarUtils) stubbed
// by the test. If a function is renamed or deleted the extraction throws
// instead of silently testing nothing.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const repo = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(repo, file), 'utf8');
const pad = indent => '^[ ]{' + indent + '}';

// `.pragma library` / `.import` are QML engine directives, not JavaScript.
// Everything below them is plain ES that Node and the Qt JS engine share.
function library(file, context = vm.createContext({})) {
    vm.runInContext(read(file).replace(/^\s*\.(pragma|import)\b.*$/gm, ''), context);
    return context;
}

// Pulls `function name(...) { ... }` out of a QML file. `indent` is the
// column the function sits at, which is what bounds the closing brace.
function functions(file, names, context, indent = 4) {
    const source = read(file);
    for (const name of names) {
        const re = new RegExp(pad(indent) + 'function ' + name + '\\([^]*?\\n[ ]{' + indent + '}\\}', 'm');
        const match = source.match(re);
        assert.ok(match, 'Missing QML function ' + name + '() in ' + file);
        // QML allows typed signatures (`function open(): string {`), which
        // plain JavaScript does not: drop the return type.
        vm.runInContext(match[0].replace(/^(\s*function\s+\w+\s*\([^)]*\))\s*:\s*[\w.<>]+/, '$1'), context);
    }
    return context;
}

// Handlers are bindings, not declarations: `Keys.onPressed: event => {...}`.
// Extract the arrow function and bind it to a name the test can call.
function handler(file, binding, context, indent, name) {
    const source = read(file);
    const re = new RegExp(pad(indent) + binding.replace(/\./g, '\\.') + ':\\s*([^]*?\\n[ ]{' + indent + '}\\})', 'm');
    const match = source.match(re);
    assert.ok(match, 'Missing QML handler ' + binding + ' in ' + file);
    vm.runInContext('var ' + name + ' = ' + match[1], context);
    return context;
}

// Property bindings are one-line expressions (`budget: Math.max(a, b)`).
// Returned as a callable so a test can feed it different stub metrics and
// assert invariants about the arithmetic the widget actually ships.
function binding(file, name, context, options = {}) {
    let source = read(file);
    if (options.after) {
        const start = source.indexOf(options.after);
        assert.ok(start >= 0, 'Missing anchor ' + options.after + ' in ' + file);
        source = source.slice(start);
    }
    const match = source.match(new RegExp('^\\s*(?:readonly\\s+)?(?:property\\s+\\w+\\s+)?' + name + ':\\s*(.+)$', 'm'));
    assert.ok(match, 'Missing QML binding ' + name + ' in ' + file);
    const expression = match[1].trim();
    const fn = vm.runInContext('(function () { return (' + expression + '); })', context);
    fn.expression = expression;
    return fn;
}

// Installs a QML binding as a live getter inside the vm, so code that reads
// the property (`contentY = todayY`) re-evaluates the shipped expression
// against the current stub state, exactly as a binding would.
function liveBinding(file, name, context, asName = name) {
    const fn = binding(file, name, context);
    context[asName + '__binding'] = fn;
    vm.runInContext('Object.defineProperty(globalThis, ' + JSON.stringify(asName) +
        ', {get: ' + asName + '__binding, configurable: true});', context);
    return fn;
}

// buildAgenda() and the phase helpers read the wall clock. Freeze it so the
// "Today" grouping is the same in CI, at midnight, and on a laptop.
function freezeClock(context, iso) {
    const now = Date.parse(iso);
    assert.ok(!Number.isNaN(now), 'Invalid frozen clock: ' + iso);
    class Frozen extends Date {
        constructor(...args) {
            super(...(args.length ? args : [now]));
        }
        static now() {
            return now;
        }
    }
    context.Date = Frozen;
    return now;
}

// Stand-in for Qt.formatDateTime()/Qt.formatTime() covering the format
// strings this plugin uses. Qt formats a JS Date in LOCAL time, which is the
// property the all-day regression depends on, so the stub does the same.
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'];

function formatDateTime(date, format) {
    const d = new Date(date);
    const h24 = d.getHours();
    const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
    const two = n => String(n).padStart(2, '0');
    return format
        .replace(/dddd/g, DAYS[d.getDay()])
        .replace(/MMMM/g, MONTHS[d.getMonth()])
        .replace(/yyyy/g, String(d.getFullYear()))
        .replace(/\bHH\b/g, two(h24))
        .replace(/\bhh\b/g, two(h12))
        .replace(/\bh\b/g, String(h12))
        .replace(/\bmm\b/g, two(d.getMinutes()))
        .replace(/\bd\b/g, String(d.getDate()))
        .replace(/\bAP\b/g, h24 < 12 ? 'AM' : 'PM');
}

const Qt = {
    formatDateTime,
    formatTime: formatDateTime,
    openUrlExternally() {},
    NoModifier: 0,
    ShiftModifier: 0x02000000,
    ControlModifier: 0x04000000,
    AltModifier: 0x08000000
};

// Enough of Qt::Key for the agenda keymap. The values only have to be
// distinct and stable within a run; the handler compares, it does not decode.
const NAMED_KEYS = {Escape: 0x01000000, Tab: 0x01000001, Return: 0x01000004, Enter: 0x01000005,
    Home: 0x01000010, End: 0x01000011, Left: 0x01000012, Up: 0x01000013, Right: 0x01000014,
    Down: 0x01000015, PageUp: 0x01000016, PageDown: 0x01000017, Space: 0x20};
for (const [name, code] of Object.entries(NAMED_KEYS))
    Qt['Key_' + name] = code;
for (let i = 0; i < 26; i++)
    Qt['Key_' + String.fromCharCode(65 + i)] = 0x41 + i;

// A key event as QML delivers it, carrying the accepted flag the handler sets.
function keyEvent(name, modifiers = Qt.NoModifier) {
    const code = Qt['Key_' + name];
    assert.ok(code !== undefined, 'Unknown key name: ' + name);
    return {key: code, modifiers, accepted: false};
}

module.exports = {read, library, functions, handler, binding, liveBinding, freezeClock, Qt, keyEvent, formatDateTime};
