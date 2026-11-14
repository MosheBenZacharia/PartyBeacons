#!/bin/sh
# Syntax-checks PartyBeacons.lua and runs it against a mock of the WoW API.
# There is no standalone Lua on this machine, so this borrows the Lua 5.1 that is
# embedded in redis-server (the same Lua version the game uses).
#
# Usage: tools/test/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
addon="$here/../../PartyBeacons/PartyBeacons.lua"
work=$(mktemp -d)
trap 'redis-cli -s ./r.sock SHUTDOWN NOSAVE >/dev/null 2>&1; rm -rf "$work"' EXIT

# A relative socket path keeps it under the 104-character limit for Unix sockets.
cd "$work"
redis-server --port 0 --unixsocket ./r.sock --save "" --appendonly no \
    --daemonize yes --dir . --pidfile ./redis.pid --logfile ./redis.log >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S ./r.sock ] && break
    perl -e 'select(undef, undef, undef, 0.3)'
done

echo "--- syntax:"
redis-cli -s ./r.sock EVAL "local f, err = loadstring(ARGV[1]) return err or 'syntax ok'" 0 "$(cat "$addon")"
echo "--- mock run:"
redis-cli -s ./r.sock EVAL "$(cat "$here/prelude.lua" "$addon" "$here/postlude.lua")" 0
