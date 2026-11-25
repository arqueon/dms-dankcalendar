#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fake_bin=$(mktemp -d)
trap 'rm -rf -- "$fake_bin"' EXIT

cat >"$fake_bin/dcal" <<'SH'
#!/usr/bin/env bash
start=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)
end=$(date -u -d '+40 minutes' +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg start "$start" --arg end "$end" '{events:[{
  summary:"Planning = review", start:$start, end:$end, allDay:false,
  location:"Room 2", description:"First line\nSecond line",
  meetingUrl:"https://meet.invalid/example", url:"https://calendar.invalid/event"
}]}'
SH
chmod +x "$fake_bin/dcal"

payload=$(PATH="$fake_bin:$PATH" "$repo_dir/get-next-event" 24 5)
jq -e '
  .summary == "Planning = review" and
  .allDay == false and
  .location == "Room 2" and
  .description == "First line\nSecond line" and
  .meetingUrl == "https://meet.invalid/example" and
  .url == "https://calendar.invalid/event"
' <<<"$payload" >/dev/null

printf '%s\n' 'next-event tests: ok'
