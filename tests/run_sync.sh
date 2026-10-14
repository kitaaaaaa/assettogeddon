#!/bin/sh
# Determinism and sync tests (see tests/sync_test.lua). Usage: sh tests/run_sync.sh <fake C1 dir>
set -e
D="$1"; T=$(mktemp -d)
echo "-- two separate runs place and move the peds identically"
luajit tests/sync_test.lua solo "$D" "$T/solo1.lua"
luajit tests/sync_test.lua solo "$D" "$T/solo2.lua"
luajit tests/sync_test.lua compare "$T/solo1.lua" "$T/solo2.lua"
echo "-- online: B only gets A's messages, and ends up with the same peds"
luajit tests/sync_test.lua clientA "$D" "$T/outbox.lua" "$T/a.lua"
luajit tests/sync_test.lua clientB "$D" "$T/outbox.lua" "$T/b.lua"
luajit tests/sync_test.lua compare "$T/a.lua" "$T/b.lua"
echo "-- replays show the same kills, forwards, rewound and jumped"
luajit tests/sync_test.lua replay "$D" "$T/replay.lua"
echo "-- a saved replay opened later shows them too"
luajit tests/sync_test.lua replayfile "$D" "$T/replay.lua"
echo "-- on a standard server: events made once, sends within the rate limit, a small queue"
luajit tests/online_test.lua "$D"
rm -rf "$T"
