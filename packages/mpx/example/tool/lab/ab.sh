#!/usr/bin/env bash
# One arm of an A/B: optionally a fresh build, then RUNS replays of one tape.
#
#   RUNS=2 LAB_SET="textures=false" tool/lab/ab.sh <label> <tape>
#   BUILD=1 tool/lab/ab.sh <label> <tape> [dart-defines...]
#
# Alternate the arms yourself (A B A B) so drift lands on both; switches
# (LAB_SET, LAB_COLD) let both arms share one build. Each run prints its
# battery temperature; a run more than 2 °C over the arm's first is marked
# HOT, and its numbers swing more than most changes do.
source "$(dirname "$0")/lab.sh"

label=${1:?label}
tape=${2:?tape name}
shift 2
if [[ "${BUILD:-0}" == 1 ]]; then "$LAB_DIR/build.sh" "$@"; fi

first=$(battery_temp)
for i in $(seq 1 "${RUNS:-2}"); do
  temp=$(battery_temp)
  hot=$(awk -v t="$temp" -v f="$first" 'BEGIN { if (t - f > 2) print " HOT" }')
  echo "$label#$i battery $temp °C$hot [${LAB_SET:-} cold=${LAB_COLD:-0}]"
  "$LAB_DIR/replay.sh" "$tape" "$label-$i" | sed "s/^/  /"
done
