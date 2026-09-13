#!/usr/bin/env bash

set -euo pipefail

tmp="${TMPDIR:-/tmp}/jkelts-check-mac.$$"
trap 'rm -f "$tmp"' EXIT

curl -fsSL https://jkasalavia.github.io/jkelts-check/mac -o "$tmp"
bash "$tmp"
