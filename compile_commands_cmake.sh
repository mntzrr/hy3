#!/usr/bin/env bash
# Its own build directory, for the same reason as compile_commands_bear.sh: a
# helper that reconfigures build/ leaves its own CMAKE_BUILD_TYPE cached there,
# so the next `cmake --build build` quietly produces a different binary than the
# documented Release configure asked for.
set -eu

cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -B build-cc
mv build-cc/compile_commands.json .
sed -i 's/-std=gnu++23/-std=gnu++2b/g' compile_commands.json
