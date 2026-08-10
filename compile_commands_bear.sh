#!/usr/bin/env bash
# Its own build directory, deliberately - this must never configure build/.
#
# HY3_NO_VERSION_CHECK is a cached CMake option. Pointing this at build/ left it
# TRUE there for every later build, including the documented reconfigure
# (`cmake -DCMAKE_BUILD_TYPE=Release -B build`), which neither reports nor
# changes it. That compiles out the commit-hash comparison in src/main.cpp - and
# since HYPRLAND_API_VERSION is the constant "0.1", that comparison is the only
# thing able to notice a build made against different Hyprland headers than the
# compositor it is being loaded into. What gets lost is the loud "target
# hyprland version mismatch" that tells you to rm -rf build and rebuild.
set -eu

rm -rf build-cc
cmake -DCMAKE_BUILD_TYPE=Debug -DHY3_NO_VERSION_CHECK=TRUE -B build-cc
bear -- cmake --build build-cc -j16
