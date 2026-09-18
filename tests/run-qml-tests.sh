#!/usr/bin/env bash
# Runs the production JavaScript library in a real Qt engine (headless).
#
#   bash tests/run-qml-tests.sh
#
# Needs the Qt 6 tools. On Arch/CachyOS /usr/bin/qmltestrunner is the Qt 5
# one, which cannot load these files, so the Qt 6 binaries are looked up
# explicitly. Without them the script says so and exits 0: the Node suites
# still cover the shared logic.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

find_qt6() {
    local name=$1 candidate
    for candidate in "/usr/lib/qt6/bin/$name" "/usr/lib64/qt6/bin/$name" "$(command -v "$name-qt6" 2>/dev/null)" "$(command -v "${name}6" 2>/dev/null)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    # A plain qmltestrunner on PATH is only usable if it is the Qt 6 build.
    candidate=$(command -v "$name" 2>/dev/null) || return 1
    [ -n "$candidate" ] && "$candidate" -help 2>&1 | grep -q . && case "$("$candidate" -v 2>&1)" in
        *" 6."*) echo "$candidate"; return 0 ;;
    esac
    return 1
}

runner=$(find_qt6 qmltestrunner) || {
    echo "SKIP: no Qt 6 qmltestrunner found (install qt6-declarative); Node suites still cover the shared logic."
    exit 0
}

export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen}
status=0
for test_file in "$here"/qml/tst_*.qml; do
    echo "== $(basename "$test_file")"
    "$runner" -input "$test_file" || status=1
done

exit "$status"
