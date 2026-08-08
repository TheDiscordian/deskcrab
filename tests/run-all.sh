#!/bin/bash
# The whole suite, one command. specs/test-harness.md names the runner
# tests/run.sh; this is the same runner under the name the suite is usually
# asked for. Every argument is passed straight through.
exec bash "$(dirname "$(readlink -f "$0")")/run.sh" "$@"
