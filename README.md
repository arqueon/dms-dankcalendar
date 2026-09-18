# dms-dankcalendar

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar widget for
[dcal / DankCalendar](https://github.com/AvengeMedia/dcal): your next event with a live
countdown in the bar, and a scrollable agenda one click away.

Fork of [leoamaro01/dms-dcal](https://github.com/leoamaro01/dms-dcal) with the click
model of [dms-dankmail](https://github.com/arqueon/dms-dankmail).

![Screenshot](assets/screenshot.png)

The agenda popout: shaded day headers, today tinted, happening-now events in green, past
events dimmed, and a floating **Today** chip to jump back when you scroll away.

## Behavior

| Action | Result |
|---|---|
| Left click | Agenda popout, opened at today |
| Click an event in the popout | Opens that event's details in DankCalendar |
| Copy button / `c` in the agenda | Copies the selected event's title, local date, schedule and location |
| Join Meeting / Join button | Opens the event's meeting link with the default URL handler |
| `+` in the popout header | Opens DankCalendar in day view to create an event |
| Right click / sync button | Requests account sync and refreshes the countdown and agenda |
| Middle click | Toggles the DankCalendar window |
| Hover | Privacy-conscious event card with schedule, location, a short description and link availability |

The agenda covers a configurable window (default 7 days back, 30 ahead), grouped by
day with shaded headers — today tinted, happening-now events in green, past events
dimmed — and a divider each time the week changes. It always opens scrolled to today.

The current timed event is highlighted with **Now**, or the next timed event with
**Next** when nothing is in progress. All-day and cancelled events do not take this
highlight; overlapping active events prefer the earliest start. Meeting buttons
appear only when an event has an HTTP(S) meeting link, including a compact button
in the bar (camera icon in vertical bars).

The bar pill keeps everything from upstream dms-dcal: scrolling event name, dot
separator, live countdown ("2h30m", "Now" while an event is starting), compact
vertical-bar layout, and the hover tooltip.
Event times in the agenda and tooltip follow DMS's 12/24-hour clock and
12-hour zero-padding preferences.

The bar offers **Title and countdown**, **Countdown only**, and **Title only**
modes. Long horizontal titles can either scroll or truncate with an ellipsis;
vertical titles stay on one line. Meeting controls remain available in every mode.

With **Dynamic Width** off, the horizontal content width stays stable as the
countdown changes or the meeting button appears. Its budget includes the calendar
icon, title, countdown, separators and Join; DMS adds its own outer padding. Very
small budgets expand to fit the controls at the current font size.

Manual refresh asks `dcal` to sync all accounts, reads the local cache immediately,
and schedules another cache read after 1.5 seconds. If a read is still running,
the follow-up is queued until it exits. Account sync is asynchronous: slower syncs
appear on the regular refresh interval (30 seconds by default). Periodic refresh
only reads the cache; it does not request extra provider syncs.

<img src="assets/screenshot-bar.png" width="420" alt="Pill in a vertical bar with the agenda popout">


## Requirements

- `dcal` (DankCalendar daemon with IPC) running
- `jq`

## Install

```bash
git clone https://github.com/arqueon/dms-dankcalendar \
  ~/.config/DankMaterialShell/plugins/dankCalendarAgenda
```

Then Settings → Plugins → Scan for Plugins, enable **Dank Calendar Agenda**, and add it
to a DankBar section.

> The install directory must be named `dankCalendarAgenda` — the widget resolves its helper
> scripts through that path.

## Keyboard navigation

Open the agenda to use these keys:

| Key | Action |
|---|---|
| `↑` / `k`, `↓` / `j` | Select the previous/next event, skipping day and week headers |
| `Enter` | Open the selected event's details |
| `t` / `Home` | Return to today |
| `c` | Copy the selected event |
| `Ctrl+R` | Request account sync and refresh the agenda |
| `Esc` | Close the agenda |

The selected row has a focus outline and scrolls into view. Its event identity is
preserved across refreshes, including recurring occurrences. Copy and Join have
their own click targets, separate from opening event details.

## IPC and Niri shortcuts

The plugin exposes one IPC target shared by its bar instances:

```bash
dms ipc dankCalendarAgenda open
dms ipc dankCalendarAgenda close
dms ipc dankCalendarAgenda toggle
dms ipc dankCalendarAgenda refresh
dms ipc dankCalendarAgenda status
```

Opening and closing are idempotent. Commands route to an instance on the focused
monitor, with a fallback to an available instance; one refresh command requests
one account sync. The widget must be enabled and present in a DankBar.
The examples disable key repeat, and holding `Ctrl+R` inside the agenda only
refreshes once. A surface that fails to open can be retried after 1.5 seconds.

Example Niri bindings (choose keys that are free in your configuration):

```kdl
binds {
    Mod+Alt+C repeat=false { spawn "dms" "ipc" "dankCalendarAgenda" "toggle"; }
    Mod+Alt+R repeat=false { spawn "dms" "ipc" "dankCalendarAgenda" "refresh"; }
}
```

## Settings

- **Refresh Interval** — how often to re-fetch events (seconds)
- **Dynamic Width** — shrink the horizontal pill to its contents
- **Bar Display** — title and countdown, countdown only, or title only
- **Scroll Long Titles** — animate overflowing horizontal titles or truncate them
- **Hover Tooltip** — toggle the next-event hover tooltip
- **Bar Content Width** — horizontal content budget, including the controls (120–600 px)
- **Now Duration** — how long to show "Now" after an event starts
- **Agenda: Days Back** — past days kept scrollable in the popout (0–90, default 7)
- **Agenda: Days Ahead** — upcoming days the popout covers (7–90, default 30)
- **Look Ahead** — how many days ahead the countdown searches

### Width setting upgrade from 1.4

`barContentWidth` replaces the title-only `pillMaxWidth` setting. Until a new width
is saved, the plugin derives its budget as the old title width plus 100 px, clamped
to 120–600 px (260 px for the old default). The old value remains available as a
fallback; it is not silently reinterpreted as a total width.

## Tests

```bash
bash tests/run-all.sh
```

Node.js is only needed for the JavaScript regression tests, not to run the widget.
The suites execute the shipped QML/JS logic with simulated processes and calendars.
If Qt 6's `qmltestrunner` is installed, the helper library also runs in the actual
QML engine; otherwise that part reports a skip. Live DMS is needed to verify the
complete rendered widget, desktop focus and pointer interactions.

## License

GPL-3.0-or-later. The upstream code this plugin forks from is MIT © 
[Leonardo Amaro](https://github.com/leoamaro01) — see `LICENSE.upstream`.

## Credits

- Original plugin by [Leonardo Amaro](https://github.com/leoamaro01) (MIT).
- Popout/click pattern from [dms-dankmail](https://github.com/arqueon/dms-dankmail).
- Bar modes, title-width budgeting, keyboard navigation and copy/IPC ideas adapted
  from [luckjokerwang's Dank Calendar Plus](https://github.com/luckjokerwang/dms-dankcalendar)
  (GPL-3.0-or-later).
- The screenshot shows fictitious demo events.
