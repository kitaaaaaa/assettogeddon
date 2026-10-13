#!/bin/sh
# Builds the BeamNG mod: the extension and its folder from beamng/mod, plus the Assetto Corsa app (carmapeds.lua)
# and its modules (src/*.lua), unchanged, as the code the extension runs. Output: beamng/carmapeds_beamng.zip
# (unzip into BeamNG's mods/unpacked/carmapeds/, or drop the zip into mods/).
# sh beamng/build.sh   (from the repo root)
set -e
cd "$(dirname "$0")"
OUT=build/carmapeds
rm -rf build
mkdir -p "$OUT"
cp -r mod/. "$OUT/"
mkdir -p "$OUT/lua/ge/extensions/carmapeds/src"
cp ../carmapeds.lua "$OUT/lua/ge/extensions/carmapeds/app.lua"
cp ../src/*.lua "$OUT/lua/ge/extensions/carmapeds/src/"
rm -f carmapeds_beamng.zip
(cd "$OUT" && zip -qr ../../carmapeds_beamng.zip .)
echo "built beamng/carmapeds_beamng.zip"
