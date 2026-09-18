# Style lock — Dank Calendar Agenda

Established: 2026-09-18. Source: existing 1.4.0 widget, DMS components and the approved bar/navigation scope.

## Palette and typography
- Inherit DMS's live `Theme` palette and font through `StyledText`, `NumericText` and `DankIcon`.
- Surfaces: `Theme.surfaceContainerHigh`; text: `Theme.surfaceText` / `Theme.surfaceVariantText`.
- Calendar, countdown, Join and selection: `Theme.primary` with existing translucent fills.
- Small bar/row text: `Theme.fontSizeSmall`; header: existing `Theme.fontSizeLarge + 2`.
- Light/dark colors and contrast are supplied by the desktop theme, not a static web palette.

## Shape and density
- Preserve the compact pill, 440px agenda popout, shaded day headers and 52px event rows.
- Use `Theme.spacingXS/S/M`, `Theme.cornerRadiusSmall` and DMS action buttons.
- Keyboard selection gets a full-primary outline; the current/next event keeps its subtler fill.
- Copy and Join have separate click targets from the event-details area.

## Assets and motion
- Reuse DMS Material icons: calendar_today, videocam, content_copy, sync, add, close.
- This native utility needs no photos, illustrations or web animation libraries.
- Retain the existing restrained scroll-to-today animation and optional title marquee.
- Stop marquee when disabled or unnecessary; truncate vertical titles on one line.

## Review
- Scope approved in conversation; final visual treatment pending runtime verification.
