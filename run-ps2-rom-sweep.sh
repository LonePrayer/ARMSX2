#!/usr/bin/env bash
# Sweep every PS2 ISO on the device through the existing single-ROM test driver.
set -euo pipefail

DEVICE_HOST="${DEVICE_HOST:-192.168.0.13}"
APP_BUNDLE="${APP_BUNDLE:-sb.cemuios.cemuios.4QYW94SHKR}"
CONTROL_KEY="${CONTROL_KEY:-amethyst-automation:${APP_BUNDLE}}"
SOFTWARE_DIR="${SOFTWARE_DIR:-/private/var/mobile/Containers/Shared/AppGroup/62FE669A-6147-4D1A-955E-6B14A3A00701/File Provider Storage/PS2/Software}"
TEST_DRIVER="${TEST_DRIVER:-/Users/sb/project/ARMSX2/run-ps2-test.sh}"
VERSION_PREFIX="${VERSION_PREFIX:-2606010042-rom}"
SWEEP_DIR="${SWEEP_DIR:-/tmp/amethyst-rom-sweep-$(date +%Y%m%d%H%M%S)}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-90}"
START_INDEX="${START_INDEX:-1}"
END_INDEX="${END_INDEX:-9999}"
ONLY_ROM_REGEX="${ONLY_ROM_REGEX:-}"
INCLUDE_BASELINE="${INCLUDE_BASELINE:-0}"
ROM_TSV_INPUT="${ROM_TSV_INPUT:-}"

mkdir -p "$SWEEP_DIR"

ROM_JSON="$SWEEP_DIR/roms.json"
ROM_TSV="$SWEEP_DIR/roms.tsv"
RESULTS_TSV="$SWEEP_DIR/results.tsv"
INTERRUPTED=0

trap 'INTERRUPTED=1' INT TERM

if [[ -n "$ROM_TSV_INPUT" ]]; then
  cp "$ROM_TSV_INPUT" "$ROM_TSV"
else
  node /Users/sb/project/Amethyst-iOS/Tools/amethystctl.mjs command file.list "{\"path\":\"${SOFTWARE_DIR}\"}" \
    --host "$DEVICE_HOST" \
    --bundle "$APP_BUNDLE" \
    --key "$CONTROL_KEY" \
    --no-wake >"$ROM_JSON"

  python3 - "$ROM_JSON" >"$ROM_TSV" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1]))
if not payload.get("ok"):
    raise SystemExit(payload.get("error", "file.list failed"))
items = payload["result"]["items"]
roms = [
    item for item in items
    if not item.get("directory")
    and item.get("name", "").lower().endswith((".iso", ".chd", ".cso"))
]
roms.sort(key=lambda item: item["name"].lower())
for index, item in enumerate(roms, 1):
    print(f"{index}\t{item['name']}\t{item['path']}")
PY
fi

printf 'index\tname\toutcome\trc\trequested_path\tobserved_iso\tlog_dir\trun_log\n' >"$RESULTS_TSV"

printf 'sweep_dir=%s\n' "$SWEEP_DIR"
printf 'rom_count=%s\n' "$(wc -l <"$ROM_TSV" | tr -d ' ')"
printf 'results=%s\n' "$RESULTS_TSV"

while IFS=$'\t' read -r index name rom_file; do
  if (( INTERRUPTED != 0 )); then
    printf 'interrupted; stopping before index=%s\n' "$index" >&2
    exit 130
  fi

  if (( index < START_INDEX || index > END_INDEX )); then
    continue
  fi
  if [[ -n "$ONLY_ROM_REGEX" ]] && ! [[ "$name" =~ $ONLY_ROM_REGEX ]]; then
    continue
  fi

  version="${VERSION_PREFIX}$(printf '%02d' "$index")"
  run_log="$SWEEP_DIR/${version}.log"
  log_dir="/tmp/amethyst-ps2-logs-${version}"

  printf '\n===== [%s] %s =====\n' "$index" "$name"
  if [[ "$name" == "God of War (USA).iso" && "$INCLUDE_BASELINE" != "1" ]]; then
    printf 'skip: known baseline STABLE_RENDERED_90s on 2606010042\n' | tee "$run_log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$name" "STABLE_RENDERED_90s_BASELINE" "0" "$rom_file" "$rom_file" "/tmp/amethyst-ps2-logs-2606010042" "$run_log" >>"$RESULTS_TSV"
    continue
  fi

  set +e
  SKIP_BUILD_INSTALL=1 \
  AM_PS2_TEST_ISO="$rom_file" \
  AM_PS2_RENDERER="${AM_PS2_RENDERER:-metal}" \
  AM_PS2_CPU="${AM_PS2_CPU:-jit}" \
  AM_PS2_SPEEDHACKS="${AM_PS2_SPEEDHACKS:-fast}" \
  AM_PS2_WAIT_LOOP="${AM_PS2_WAIT_LOOP:-1}" \
  AM_PS2_INTC_STAT="${AM_PS2_INTC_STAT:-1}" \
  AM_PS2_MVU_FLAG="${AM_PS2_MVU_FLAG:-1}" \
  AM_PS2_INSTANT_VU1="${AM_PS2_INSTANT_VU1:-1}" \
  AM_PS2_VU_DIAG="${AM_PS2_VU_DIAG:-0}" \
  AM_PS2_PRESENT_SAMPLE="${AM_PS2_PRESENT_SAMPLE:-0}" \
  MAX_WAIT_SEC="$MAX_WAIT_SEC" \
  "$TEST_DRIVER" "$version" 2>&1 | tee "$run_log"
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc == 130 || rc == 143 || INTERRUPTED != 0 )); then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$name" "INTERRUPTED" "$rc" "$rom_file" "" "$log_dir" "$run_log" >>"$RESULTS_TSV"
    exit "$rc"
  fi

  outcome="$(grep -E 'OUTCOME:' "$run_log" | tail -1 | sed -E 's/^.*OUTCOME: //' || true)"
  if [[ -z "$outcome" ]]; then
    outcome="NO_OUTCOME"
  fi

  observed_iso="$(
    {
      awk '/\[PS2\] Starting game=/ { line = $0 } END { if (line) { sub(/^.*Starting game=/, "", line); sub(/ bios=.*$/, "", line); print line } }' "$log_dir/automation.log" 2>/dev/null || true
      awk '/Start request iso=/ { line = $0 } END { if (line) { sub(/^.*Start request iso=/, "", line); sub(/ bios=.*$/, "", line); print line } }' "$log_dir/armsx2-amethyst.log" 2>/dev/null || true
    } | awk 'NF { print; exit }' || true
  )"
  if [[ -z "$observed_iso" ]]; then
    observed_iso="UNKNOWN"
  fi
  if [[ "$observed_iso" != "$rom_file" ]]; then
    outcome="ISO_MISMATCH"
    rc=66
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$name" "$outcome" "$rc" "$rom_file" "$observed_iso" "$log_dir" "$run_log" >>"$RESULTS_TSV"
  printf 'recorded: %s -> %s rc=%s observed=%s\n' "$name" "$outcome" "$rc" "$observed_iso"

  if [[ "$outcome" == "ISO_MISMATCH" ]]; then
    printf 'ISO mismatch; stopping sweep\n' >&2
    exit "$rc"
  fi
done <"$ROM_TSV"

printf '\nRESULTS=%s\n' "$RESULTS_TSV"
column -t -s $'\t' "$RESULTS_TSV" || cat "$RESULTS_TSV"
