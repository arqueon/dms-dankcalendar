#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fake_bin=$(mktemp -d)
trap 'rm -rf -- "$fake_bin"' EXIT

# FAKE_EVENTS=fail breaks events.list; FAKE_CALENDARS=fail or =garbage
# breaks calendars.list.
cat >"$fake_bin/dcal" <<'SH'
#!/usr/bin/env bash
case "$2" in
events.list)
    [ "${FAKE_EVENTS:-ok}" = fail ] && exit 1
    jq -nc '{total: 4, events: [
      {uid: "a", calendarId: "work", start: "2026-09-18T09:00:00Z"},
      {uid: "b", calendarId: "plain", start: "2026-09-18T10:00:00Z"},
      {uid: "c", calendarId: "gone", start: "2026-09-18T11:00:00Z"},
      {uid: "d", start: "2026-09-18T12:00:00Z"}
    ]}'
    ;;
calendars.list)
    [ "${FAKE_CALENDARS:-ok}" = fail ] && exit 1
    [ "${FAKE_CALENDARS:-ok}" = garbage ] && { echo 'not json'; exit 0; }
    jq -nc '[{id: "work", color: "#4986e7"}, {id: "plain", color: ""}, {id: "other", color: "#7bd148"}]'
    ;;
*)
    exit 2
    ;;
esac
SH
chmod +x "$fake_bin/dcal"

agenda() {
    PATH="$fake_bin:$PATH" "$repo_dir/get-agenda-events" 1 1
}

# Each event gets its own calendar's color; no color, no field.
jq -e '
  .total == 4 and
  ([.events[].uid] == ["a", "b", "c", "d"]) and
  ([.events[] | has("calendarColor")] == [true, false, false, false]) and
  .events[0].calendarColor == "#4986e7"
' <<<"$(agenda)" >/dev/null

# A failed or unreadable calendars.list leaves the events untouched.
for mode in fail garbage; do
    jq -e '
      .total == 4 and
      (.events | length == 4 and all(has("calendarColor") | not))
    ' <<<"$(FAKE_CALENDARS=$mode agenda)" >/dev/null
done

# A failed events.list still yields the empty list the widget expects.
[ "$(FAKE_EVENTS=fail agenda)" = '{"events":[]}' ]

printf '%s\n' 'agenda-events tests: ok'
