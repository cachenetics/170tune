#!/usr/bin/env bash
# Build and install 170tune. Thin shim: 'tools/170tune install' is the single implementation -
# it builds every helper tool from source (SM and HBM), installs the shipped scripts and the
# boot-check unit, and migrates a box still on the old persist model. Kept as './install.sh' at
# the repo root for muscle memory; nothing here duplicates the build/install logic anymore.
exec "$(dirname "$(readlink -f "$0")")/tools/170tune" install "$@"
