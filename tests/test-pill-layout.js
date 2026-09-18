// Horizontal pill width accounting. The layout lives in QML bindings, so the
// test extracts those expressions from the widget and evaluates them against
// stub text metrics: the arithmetic under test is the shipped one, and the
// assertions are the invariants a bar has to hold (stable width, room for
// Join, a title clip that never goes negative).
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {library, binding} = require('./qmljs.js');

const WIDGET = 'DankCalendarWidget.qml';
const CalendarUtils = library('calendarUtils.js');

// Stub metrics in the ballpark of Theme.fontSizeSmall at 1x.
const context = vm.createContext({
    Math,
    Text: {ElideNone: 0, ElideRight: 3, PlainText: 0, NoWrap: 0},
    root: {},
    hRow: {spacing: 4},
    hDot: {implicitWidth: 8},
    hTime: {implicitWidth: 30},
    hJoin: {implicitWidth: 24, visible: false},
    summaryText: {implicitWidth: 120},
    timeMetrics: {advanceWidth: 62}, // "88d88h88m"
    hPill: {}
});
// Anchored at the horizontal pill: `implicitWidth` and `width` are common
// property names, and the first match in the file is a different item.
const pillBinding = name => binding(WIDGET, name, context, {after: 'id: hPill'});
const showTitle = pillBinding('showTitle');
const showTime = pillBinding('showTime');
const showDot = pillBinding('showDot');
const controlsWidth = pillBinding('controlsWidth');
const minimumBudget = pillBinding('minimumBudget');
const budget = pillBinding('budget');
const implicitWidth = pillBinding('implicitWidth');
// The title clip is an unnamed `width:` binding, so anchor the lookup.
const clipWidth = binding(WIDGET, 'width', context, {after: 'id: summaryClip'});
const overflow = binding(WIDGET, 'overflow', context, {after: 'id: summaryClip'});
const titleWidth = binding(WIDGET, 'width', context, {after: 'id: summaryText'});
const elide = binding(WIDGET, 'elide', context, {after: 'id: summaryText'});
const marqueeRunning = binding(WIDGET, 'running', context, {after: 'id: summaryText'});
assert.ok(marqueeRunning.expression.includes('summaryClip.overflow'), 'picked up the marquee condition');
assert.ok(clipWidth.expression.includes('hPill.controlsWidth'), 'picked up the summary clip width binding');

// Recompute the pill the way QML would: bindings, in dependency order.
function layout(options = {}) {
    const settings = Object.assign({
        pluginData: {},
        hasEvent: true,
        dynamicWidth: false,
        iconSize: 18,
        countdown: 30,   // "in 12m"
        title: 120,
        join: false,
        scrollTitle: true
    }, options);
    Object.assign(context.root, {
        hasEvent: settings.hasEvent,
        dynamicWidth: settings.dynamicWidth,
        iconSize: settings.iconSize,
        scrollTitle: settings.scrollTitle,
        pillDisplayMode: CalendarUtils.displayMode(settings.pluginData.pillDisplayMode),
        barContentWidth: CalendarUtils.contentWidth(settings.pluginData)
    });
    context.hTime.implicitWidth = settings.countdown;
    context.summaryText.implicitWidth = settings.title;
    context.hJoin.visible = settings.join && settings.hasEvent;
    // Sibling properties resolve unqualified inside a QML scope, so the
    // already-evaluated ones go back on the context before the next binding.
    context.showTitle = showTitle();
    context.showTime = showTime();
    context.showDot = showDot();
    context.controlsWidth = controlsWidth();
    context.minimumBudget = minimumBudget();
    context.budget = budget();
    context.summaryClip = {};
    const pill = {
        showTitle: context.showTitle,
        showTime: context.showTime,
        showDot: context.showDot,
        controlsWidth: context.controlsWidth,
        minimumBudget: context.minimumBudget,
        budget: context.budget,
        width: implicitWidth()
    };
    context.hPill = pill;
    pill.visible = true;
    pill.clip = clipWidth();  // the width left for the title
    // summaryClip's own scope: `overflow` reads an unqualified `width`.
    context.width = pill.clip;
    context.summaryClip = {width: pill.clip};
    context.summaryClip.overflow = overflow();
    pill.overflow = context.summaryClip.overflow;
    // summaryText's own scope: `implicitWidth` is its natural text width.
    context.implicitWidth = context.summaryText.implicitWidth;
    pill.titleWidth = titleWidth();
    pill.elide = elide();
    pill.marquee = marqueeRunning();
    return pill;
}

const WIDE = {pluginData: {barContentWidth: 320}};

// --- 1. A fixed-width pill does not twitch as the countdown changes ---
// "in 2h" -> "in 1h59m" -> "Now" used to move the whole bar.
const widths = ['in 2h', 'in 1h59m', 'Now', '88d88h88m'].map((label, i) =>
    layout(Object.assign({countdown: [22, 48, 26, 62][i]}, WIDE)).width);
assert.equal(new Set(widths).size, 1, 'the pill width is the same for every countdown string');
assert.equal(widths[0], 320, 'and it is the configured budget');
// The title takes the slack instead, and always has some room left.
const clips = ['in 2h', '88d88h88m'].map((label, i) =>
    layout(Object.assign({countdown: [22, 62][i]}, WIDE)).clip);
assert.ok(clips[0] > clips[1], 'a longer countdown shrinks the title, not the pill');
assert.ok(clips.every(c => c > 0), 'the title never loses all of its room');

// --- 2. Join takes its width out of the title, never out of the pill ---
const withoutJoin = layout(WIDE);
const withJoin = layout(Object.assign({join: true}, WIDE));
assert.equal(withJoin.width, withoutJoin.width, 'adding a Join button does not widen the bar');
assert.equal(withJoin.clip, withoutJoin.clip - (24 + 4), 'Join is paid for out of the title');
assert.ok(withJoin.clip > 0, 'title, countdown and Join all fit inside the budget');

// --- 3. The budget can never be squeezed below what the controls need ---
const narrow = layout({pluginData: {barContentWidth: 120}, join: true});
assert.ok(narrow.budget >= narrow.minimumBudget, 'a narrow setting is lifted to the minimum budget');
assert.ok(narrow.budget > 120, 'the 120px slider minimum is not enough for icon + countdown + Join');
assert.ok(narrow.clip >= 0, 'the title clip never goes negative');
assert.ok(narrow.width >= narrow.controlsWidth, 'the controls always fit the pill');
// And that holds for the worst case: longest countdown, Join visible, tiny setting.
const worst = layout({pluginData: {barContentWidth: 120}, join: true, countdown: 62, title: 400});
assert.ok(worst.clip >= 0 && worst.width >= worst.controlsWidth);

// --- 4. Display modes drop the parts they say they drop ---
const full = layout(WIDE);
assert.ok(full.showTitle && full.showTime && full.showDot, 'full shows title, dot and countdown');

const countdownOnly = layout({pluginData: {pillDisplayMode: 'countdownOnly', barContentWidth: 320}});
assert.equal(countdownOnly.showTitle, false);
assert.equal(countdownOnly.showTime, true);
assert.equal(countdownOnly.showDot, false, 'no separator with nothing to separate');

const titleOnly = layout({pluginData: {pillDisplayMode: 'titleOnly', barContentWidth: 320}});
assert.equal(titleOnly.showTime, false);
assert.equal(titleOnly.showDot, false);
assert.ok(titleOnly.minimumBudget < full.minimumBudget, 'title-only stops reserving countdown space');
assert.ok(titleOnly.clip > full.clip, 'and hands that space to the title');

// With no event at all the pill still shows "No events", in every mode.
for (const mode of ['full', 'countdownOnly', 'titleOnly']) {
    const empty = layout({hasEvent: false, pluginData: {pillDisplayMode: mode, barContentWidth: 320}});
    assert.equal(empty.showTitle, true, mode + ': "No events" is always visible');
    assert.equal(empty.showTime, false, mode + ': no countdown without an event');
    assert.ok(empty.clip > 0, mode + ': and it has room to render');
}

// --- 5. Dynamic width shrinks to the content but never past the budget ---
const short = layout({dynamicWidth: true, title: 40, pluginData: {barContentWidth: 320}});
const long = layout({dynamicWidth: true, title: 400, pluginData: {barContentWidth: 320}});
assert.ok(short.width < short.budget, 'a short title gives the bar its space back');
assert.ok(short.width >= short.controlsWidth, 'but never clips the icon or the countdown');
assert.equal(long.width, long.budget, 'a long title stops at the configured budget');
assert.ok(long.width >= short.width);
const dynamicJoin = layout({dynamicWidth: true, title: 40, join: true, pluginData: {barContentWidth: 320}});
assert.equal(dynamicJoin.width, short.width + 24 + 4, 'Join adds its own width when the bar is dynamic');

// --- 6. The title marquee only runs when it has something to scroll ---
// scrollTitle on: animate an overflowing title, hold still when it fits.
const scrolls = Object.assign({scrollTitle: true}, WIDE);
assert.equal(layout(Object.assign({title: 400}, scrolls)).marquee, true, 'a long title scrolls');
assert.equal(layout(Object.assign({title: 40}, scrolls)).marquee, false, 'a title that fits does not');
assert.equal(layout(Object.assign({title: 400}, scrolls)).elide, 0, 'and it is not elided while scrolling');
// scrollTitle off: one line, ellipsis, never an animation.
const statics = Object.assign({scrollTitle: false}, WIDE);
assert.equal(layout(Object.assign({title: 400}, statics)).marquee, false, 'the marquee can be turned off');
assert.equal(layout(Object.assign({title: 400}, statics)).elide, 3, 'and the title is elided instead');
assert.equal(layout(Object.assign({title: 400}, statics)).titleWidth,
    layout(Object.assign({title: 400}, statics)).clip, 'a static title is bound to the clip width');
assert.ok(layout(Object.assign({title: 400}, scrolls)).titleWidth > layout(Object.assign({title: 400}, scrolls)).clip,
    'a scrolling title is wider than its clip, which is what makes it move');
// Countdown-only hides the title, so nothing may animate off screen.
assert.equal(layout({title: 400, scrollTitle: true, pluginData: {pillDisplayMode: 'countdownOnly', barContentWidth: 320}}).marquee,
    false, 'no title, no marquee');

// --- 7. Legacy settings land on a usable pill ---
const migrated = layout({pluginData: {pillMaxWidth: 160}});
assert.equal(migrated.budget, 260, '1.4 defaults migrate to the 260 budget');
assert.ok(migrated.clip > 0, 'and a 1.4 config still has room for its title');

console.log('Pill layout tests: ok');
