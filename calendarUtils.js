.pragma library

// Presentation and keyboard ideas adapted from luckjokerwang/dms-dankcalendar (GPL-3.0-or-later).
function contentWidth(settings) {
    // v1.4 used pillMaxWidth for the title alone. Keep it as a read-only fallback.
    var width = settings.barContentWidth;
    if (width === undefined || width === null)
        width = (Number(settings.pillMaxWidth) || 160) + 100;
    return Math.max(120, Math.min(600, Number(width) || 260));
}

function displayMode(value) {
    return value === "countdownOnly" || value === "titleOnly" ? value : "full";
}

function eventKey(ev) {
    return ev ? JSON.stringify([ev.calendarId || "", ev.uid || ev.id || "", ev.start || ""]) : "";
}

function eventIndices(model) {
    var indices = [];
    for (var i = 0; i < model.length; i++) {
        if (model[i].kind === "event")
            indices.push(i);
    }
    return indices;
}

function selectionIndex(model, key, preferredKey, todayOffset) {
    var indices = eventIndices(model);
    for (var index of indices) {
        if (key && eventKey(model[index].ev) === key)
            return index;
    }
    for (var index of indices) {
        if (preferredKey && eventKey(model[index].ev) === preferredKey)
            return index;
    }
    for (var index of indices) {
        if (rowOffset(model, index) >= todayOffset)
            return index;
    }
    return indices.length ? indices[indices.length - 1] : -1;
}

function stepSelection(model, index, direction) {
    var indices = eventIndices(model);
    if (!indices.length)
        return -1;
    var position = indices.indexOf(index);
    if (position < 0)
        return direction < 0 ? indices[indices.length - 1] : indices[0];
    return indices[Math.max(0, Math.min(indices.length - 1, position + direction))];
}

function rowOffset(model, index) {
    var offset = 0;
    for (var i = 0; i < index; i++)
        offset += model[i].kind === "event" ? 54 : (model[i].kind === "day" ? 34 : 30);
    return offset;
}

function visibleScroll(offset, rowHeight, scroll, viewport, contentHeight) {
    var next = scroll;
    if (offset < scroll)
        next = offset;
    else if (offset + rowHeight > scroll + viewport)
        next = offset + rowHeight - viewport;
    return Math.max(0, Math.min(next, Math.max(0, contentHeight - viewport)));
}

function eventCopyText(ev, dateText, timeText) {
    var lines = [String(ev?.summary || "(untitled)")];
    if (dateText)
        lines.push(dateText + (timeText ? " · " + timeText : ""));
    if (ev?.location)
        lines.push(String(ev.location));
    return lines.join("\n");
}
