# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Dank Material Shell (DMS) plugin showing the next calendar event from
[dcal](https://github.com/AvengeMedia/dcal) with a live countdown, plus a popout listing
today's events. Plugin ID: `dankCalendarAgenda`. Fork of
[leoamaro01/dms-dcal](https://github.com/leoamaro01/dms-dcal) with the dms-dankmail click
model: left click opens the popout, clicking an event runs `dcal ipc ui.openEvent`, right
click refreshes, middle click runs `dcal ipc ui.toggle view=day`. Hover still shows the
next-event tooltip.

## Development

No build step. Pure QML + two bash helper scripts, loaded by the DMS plugin runtime.
Run `bash tests/test-next-event.sh`, `node tests/test-widget-customizations.js`,
and `node tests/test-refresh.js`; validate scripts with `bash -n` and ShellCheck.
Test locally by symlinking the repo to
`~/.config/DankMaterialShell/plugins/dankCalendarAgenda/` (the directory name matters — script
paths are resolved as `PluginService.pluginDirectory + "/dankCalendarAgenda/..."`), then
`dms ipc plugin-scan reload dankCalendarAgenda` or restart the shell.

Runtime dependencies: `dcal` (calendar daemon with IPC) and `jq`.

## Architecture

- **`plugin.json`** — DMS plugin manifest.
- **`DankCalendarWidget.qml`** — Main widget. Fetches the next event via `get-next-event`
  (compact JSON, StdioCollector) and the agenda via `get-agenda-events` (raw JSON,
  StdioCollector) on the same refresh timer. Renders the countdown pill (horizontal and
  vertical), the hover tooltip (layer-shell PanelWindow, empty input region), and the
  popout: a dankmail-style custom header plus a flat display model built by
  `buildAgenda()` — "week" divider / shaded "day" header / "event" rows with fixed
  per-kind heights, so the total height (and the scroll offset of today, used to pin
  the list to today on open) is known before DankPopout positions the surface. Rows dim
  when past and go green while happening.
- **`DankCalendarSettings.qml`** — `PluginSettings` form writing to `pluginData`.
- **`get-next-event`** — Next upcoming event within the look-ahead window, emitted
  as compact JSON including meeting links and tooltip details.
- **`get-agenda-events PAST FUTURE`** — Emits `dcal ipc events.list` JSON for local
  midnight−PAST days → local midnight+FUTURE days. Local→UTC conversion goes through an
  epoch because `date -u -d` parses its input as UTC; the widget sorts (by day, all-day
  first within a day, then by start).

## DMS Plugin Conventions

QML files import DMS-provided namespaces (`qs.Common`, `qs.Widgets`, `qs.Services`,
`qs.Modules.Plugins`) that have no external documentation. Settings are read as
`pluginData.<key> || <default>`. With `popoutContent` set, left click opens the popout
automatically; `pillRightClickAction` handles right click; middle click needs a
`MouseArea` with `acceptedButtons: Qt.MiddleButton` (and negative margins to cover the
BasePill padding) so left/right fall through.
