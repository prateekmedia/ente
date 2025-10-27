#!/usr/bin/env bash
# Automates video editor trim/crop/rotate combinations via axe taps.

set -euo pipefail

DEFAULT_UDID="0D2EB41C-2FB0-46BE-ACD4-31394028BEF7"
UDID="$DEFAULT_UDID"
DEFAULT_VIDEO_INDEX=1
VIDEO_INDEX="$DEFAULT_VIDEO_INDEX"
VARIANT=1
TRIM_VARIANT=1
VIDEO_LIST=""
TRIM_FILTER="all"
DRY_RUN=0

AXE_BIN="${AXE_BIN:-axe}"
AXE_VERBOSE="${AXE_VERBOSE:-0}"

SLEEP_AFTER_TAP="${SLEEP_AFTER_TAP:-0.8}"
SLEEP_AFTER_SWIPE="${SLEEP_AFTER_SWIPE:-1.0}"
SLEEP_AFTER_CONFIRM="${SLEEP_AFTER_CONFIRM:-1.2}"

usage() {
  cat <<EOF
Usage: $0 [--udid <device-udid>] [--video <1|2|3>] [--videos <list>] [--variant <1|2>] [--trim-variant <1|2>] [--trim-filter <all|trim-only|no-trim>] [--dry-run]

Options:
  --udid <value>   Override the simulator/device UDID (default: ${DEFAULT_UDID}).
  --video <index>  Choose the source video tile (1, 2, or 3). Default: 1.
  --videos <list>  Comma or space separated list of videos to run (e.g. "1,2,3"). Overrides --video.
  --variant <1|2>  Crop sweep variant (1 keeps 9:16, 2 swaps to 16:9). Default: 1.
  --trim-variant <1|2>  Trim swipe variant (1 = legacy left-to-right, 2 = new right-to-left). Default: 1.
  --trim-filter <all|trim-only|no-trim>
                   Restrict crop cases to only trimmed or only non-trimmed runs. Default: all.
  --dry-run        Print axe commands without executing them.
  -h, --help       Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      [[ $# -ge 2 ]] || { echo "error: --udid requires a value" >&2; exit 1; }
      UDID="$2"
      shift 2
      ;;
    --video)
      [[ $# -ge 2 ]] || { echo "error: --video requires a value" >&2; exit 1; }
      VIDEO_INDEX="$2"
      shift 2
      ;;
    --videos)
      [[ $# -ge 2 ]] || { echo "error: --videos requires a value" >&2; exit 1; }
      VIDEO_LIST="$2"
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || { echo "error: --variant requires a value" >&2; exit 1; }
      VARIANT="$2"
      shift 2
      ;;
    --trim-variant)
      [[ $# -ge 2 ]] || { echo "error: --trim-variant requires a value" >&2; exit 1; }
      TRIM_VARIANT="$2"
      shift 2
      ;;
    --trim-filter)
      [[ $# -ge 2 ]] || { echo "error: --trim-filter requires a value" >&2; exit 1; }
      TRIM_FILTER=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

VIDEO_INDICES_RAW=()
if [[ -n "$VIDEO_LIST" ]]; then
  tmp_list=${VIDEO_LIST//,/ }
  read -ra VIDEO_INDICES_RAW <<< "$tmp_list"
else
  VIDEO_INDICES_RAW=("$VIDEO_INDEX")
fi

VIDEO_INDICES=()
for entry in "${VIDEO_INDICES_RAW[@]}"; do
  idx="${entry//[[:space:]]/}"
  if [[ -z "$idx" ]]; then
    continue
  fi
  if [[ ! "$idx" =~ ^[123]$ ]]; then
    echo "error: unsupported video index $idx. Allowed values: 1, 2, 3." >&2
    exit 1
  fi
  VIDEO_INDICES+=("$idx")
done

if [[ ${#VIDEO_INDICES[@]} -eq 0 ]]; then
  echo "error: no video indices provided." >&2
  exit 1
fi

CURRENT_VIDEO_INDEX="${VIDEO_INDICES[0]}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

rest() {
  local seconds=$1
  (( DRY_RUN )) && return 0
  sleep "$seconds"
}

run_axe() {
  if (( DRY_RUN )); then
    printf 'DRY-RUN: %s\n' "$*"
  else
    if (( AXE_VERBOSE )); then
      "$@"
    else
      "$@" >/dev/null 2>&1
    fi
  fi
}

tap() {
  local x=$1
  local y=$2
  local message=${3:-"tap(${x},${y})"}
  log "$message"
  run_axe "$AXE_BIN" tap --udid "$UDID" -x "$x" -y "$y"
  rest "$SLEEP_AFTER_TAP"
}

swipe() {
  local sx=$1
  local sy=$2
  local ex=$3
  local ey=$4
  local duration=$5
  log "swipe(${sx},${sy} -> ${ex},${ey}, ${duration}s)"
  run_axe "$AXE_BIN" swipe --udid "$UDID" --start-x "$sx" --start-y "$sy" --end-x "$ex" --end-y "$ey" --duration "$duration"
  rest "$SLEEP_AFTER_SWIPE"
}

tap_confirm() {
  local label=$1
  tap 450 80 "$label"
  rest "$SLEEP_AFTER_CONFIRM"
}

tap_tool_done() {
  tap_confirm "confirm tool"
}

tap_save_copy() {
  tap_confirm "save copy"
}

select_video() {
  case "$1" in
    1) tap 40 200 "select video 1" ;;
    2) tap 40 350 "select video 2" ;;
    3) tap 40 500 "select video 3" ;;
    *) echo "error: unsupported video index $1" >&2; exit 1 ;;
  esac
  rest 1.2
}

open_editor() {
  tap 160 800 "open video editor"
  rest 1.5
}

apply_trim() {
  log "apply trim"
  tap 80 750 "open trim tool"
  rest 0.8
  if [[ "$TRIM_VARIANT" == "2" ]]; then
    swipe 370 800 75 800 0.3
  else
    swipe 60 800 400 800 0.3
  fi
  rest 0.6
  tap_tool_done
}

reset_crop_strip_to_default() {
  swipe 0 750 350 750 0.3
  rest 0.4
}

show_extended_crop_strip() {
  swipe 350 750 0 750 0.3
  rest 0.4
}

apply_crop() {
  local ratio=$1
  log "apply crop ${ratio}"
  tap 200 750 "open crop tool"
  rest 0.8
  reset_crop_strip_to_default
  if [[ "$ratio" == "16:9" || "$ratio" == "3:4" || "$ratio" == "4:3" ]]; then
    show_extended_crop_strip
  fi
  case "$ratio" in
    "1:1") tap 200 750 "set crop 1:1" ;;
    "9:16") tap 300 750 "set crop 9:16" ;;
    "16:9") tap 100 750 "set crop 16:9" ;;
    "3:4") tap 200 750 "set crop 3:4" ;;
    "4:3") tap 300 750 "set crop 4:3" ;;
    *)
      echo "error: unsupported crop ratio $ratio" >&2
      exit 1
      ;;
  esac
  rest 0.6
  tap_tool_done
}

apply_rotate() {
  local degrees=$1
  log "apply rotate ${degrees}°"
  tap 300 750 "open rotate tool"
  rest 0.8
  local normalized=$(( (degrees % 360 + 360) % 360 ))
  local steps=$(( normalized / 90 ))
  for ((i = 0; i < steps; ++i)); do
    tap 250 750 "rotate right"
    rest 0.5
  done
  tap_tool_done
}

has_saving_dialog() {
  (( DRY_RUN )) && return 1
  if "$AXE_BIN" describe-ui --udid "$UDID" 2>/dev/null | grep -q "Saving edits"; then
    return 0
  fi
  return 1
}

wait_for_save_completion() {
  log "wait for save completion"
  rest 5
  if has_saving_dialog; then
    log "saving dialog present, waiting extra 10s"
    rest 10
    local attempts=0
    while has_saving_dialog; do
      attempts=$((attempts + 1))
      log "saving dialog still visible (attempt ${attempts}), waiting another 10s"
      rest 10
    done
    if (( attempts == 0 )); then
      log "saving dialog cleared after extended wait"
    else
      log "saving dialog cleared after ${attempts} additional attempts"
    fi
  else
    log "no saving dialog detected"
  fi
  rest 1.0
}

run_case() {
  local case_name=$1
  local trim_flag=$2
  local crop_ratio=$3
  local rotate_degrees=$4

  log "=== case ${case_counter}: ${case_name} ==="
  select_video "$CURRENT_VIDEO_INDEX"
  open_editor

  if [[ "$trim_flag" == "yes" ]]; then
    apply_trim
  fi

  if [[ "$crop_ratio" != "none" ]]; then
    apply_crop "$crop_ratio"
  fi

  if [[ "$rotate_degrees" != "none" ]]; then
    apply_rotate "$rotate_degrees"
  fi

  tap_save_copy
  wait_for_save_completion
  rest 1.5
  ((case_counter++))
}

trap 'log "interrupted"; exit 1' INT TERM

case "$VARIANT" in
  1)
    crop_ratios=("1:1" "3:4" "4:3" "16:9")
    ;;
  2)
    crop_ratios=("1:1" "3:4" "4:3" "9:16")
    ;;
  *)
    echo "error: unsupported variant $VARIANT. Allowed values: 1, 2." >&2
    exit 1
    ;;
esac

if [[ ! "$TRIM_VARIANT" =~ ^[12]$ ]]; then
  echo "error: unsupported trim variant $TRIM_VARIANT. Allowed values: 1, 2." >&2
  exit 1
fi

case "$TRIM_FILTER" in
  all|trim-only|no-trim)
    ;;
  *)
    echo "error: unsupported trim filter $TRIM_FILTER. Allowed values: all, trim-only, no-trim." >&2
    exit 1
    ;;
esac

log "selected variant $VARIANT with crop ratios: ${crop_ratios[*]}"
log "selected trim variant $TRIM_VARIANT"
log "selected trim filter $TRIM_FILTER"

for video_index in "${VIDEO_INDICES[@]}"; do
  CURRENT_VIDEO_INDEX="${video_index}"
  log "--- video ${CURRENT_VIDEO_INDEX}: starting ---"
  case_counter=1

  run_case "video${CURRENT_VIDEO_INDEX}-trim-only" "yes" "none" "none"

  for rotation in 0 90 180 270; do
    run_case "video${CURRENT_VIDEO_INDEX}-rotate-${rotation}" "yes" "none" "$rotation"
  done

  for ratio in "${crop_ratios[@]}"; do
    for trim_state in yes no; do
      if [[ "$TRIM_FILTER" == "trim-only" && "$trim_state" == "no" ]]; then
        continue
      fi
      if [[ "$TRIM_FILTER" == "no-trim" && "$trim_state" == "yes" ]]; then
        continue
      fi
      for rotation in 0 90 180 270; do
        suffix=$([[ "$trim_state" == "yes" ]] && echo "trim" || echo "no-trim")
        run_case "video${CURRENT_VIDEO_INDEX}-crop-${ratio}-${suffix}-rot${rotation}" "$trim_state" "$ratio" "$rotation"
      done
    done
  done

  log "--- video ${CURRENT_VIDEO_INDEX}: completed ---"
done

log "all videos completed"
