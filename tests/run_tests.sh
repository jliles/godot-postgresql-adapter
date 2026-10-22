#!/usr/bin/env bash
# Runs the adapter tests against a throwaway PostgreSQL database (they create and drop a table
# named adapter_test). Build the extension first (debug target).
#
#   PG_TEST_URL=postgresql://user@127.0.0.1:5432/adapter_test tests/run_tests.sh
#
# The database name must contain "test". GODOT selects the engine binary (default: godot).
set -u
cd "$(dirname "$0")"
GODOT=${GODOT:-godot}

name="${PG_TEST_URL:-}"; name="${name%%\?*}"; name="${name##*/}"
if [[ -z "${PG_TEST_URL:-}" || "${name,,}" != *test* ]]; then
    echo "PG_TEST_URL must name a throwaway database with 'test' in its name (got '${PG_TEST_URL:-}')." >&2
    exit 2
fi

mkdir -p .godot
echo "res://addons/godot-postgresql/godot-postgresql.gdextension" > .godot/extension_list.cfg
"$GODOT" --headless --path . -s test_adapter.gd 2>&1 | grep -vE "^Godot Engine|^$"
exit "${PIPESTATUS[0]}"
