#!/usr/bin/env bash
# Every test in one command: the helper script, the Node suites over the
# shipped QML/JS, and the QML suites in a real Qt engine (skipped when the
# Qt 6 tools are missing). Nothing here talks to dcal or a real calendar.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
status=0

run() {
    echo "== $*"
    "$@" || status=1
}

run bash "$here/test-next-event.sh"
for suite in "$here"/test-*.js; do
    run node "$suite"
done
run bash "$here/run-qml-tests.sh"

# Shell helpers must at least parse; ShellCheck when it is installed.
for script in "$repo/get-next-event" "$repo/get-agenda-events" "$here"/*.sh; do
    run bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
    run shellcheck -s bash "$repo/get-next-event" "$repo/get-agenda-events" "$here"/*.sh
else
    echo "-- shellcheck not installed, skipped"
fi

[ "$status" -eq 0 ] && echo "All tests passed." || echo "FAILURES above."
exit "$status"
