#!/usr/bin/env bash
# Event-driven PS2 test driver: build → install → launch → wait for keyword → pull logs.
# Replaces fixed sleeps with Monitor-style log tailing.
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
SKIP_BUILD_INSTALL="${SKIP_BUILD_INSTALL:-0}"
DEVICE=0E887F46-5FFB-53AA-AE3F-372B0E924C65
UDID=00008142-001651440CD8401C
DEVICE_IP=192.168.0.13
SIDE=com.SideStore.SideStore.4QYW94SHKR
APP=sb.cemuios.cemuios.4QYW94SHKR
DEFAULT_PS2_TEST_ISO="/private/var/mobile/Containers/Shared/AppGroup/62FE669A-6147-4D1A-955E-6B14A3A00701/File Provider Storage/PS2/Software/God of War (USA).iso"
AUTO_ISO="${AM_PS2_TEST_ISO:-$DEFAULT_PS2_TEST_ISO}"
AUTO_RENDERER="${AM_PS2_RENDERER:-software}"
AUTO_CPU="${AM_PS2_CPU:-}"
AUTO_IOP="${AM_PS2_IOP:-}"
AUTO_VU="${AM_PS2_VU:-}"
AUTO_VU0="${AM_PS2_VU0:-}"
AUTO_VU1="${AM_PS2_VU1:-}"
AUTO_SPEEDHACKS="${AM_PS2_SPEEDHACKS:-}"
AUTO_WAIT_LOOP="${AM_PS2_WAIT_LOOP:-}"
AUTO_INTC_STAT="${AM_PS2_INTC_STAT:-}"
AUTO_MVU_FLAG="${AM_PS2_MVU_FLAG:-}"
AUTO_INSTANT_VU1="${AM_PS2_INSTANT_VU1:-}"
AUTO_VERBOSE_CORE="${AM_PS2_VERBOSE_CORE_LOG:-}"
AUTO_FRAMEBUFFER_FETCH="${AM_PS2_FRAMEBUFFER_FETCH:-}"
AUTO_VERTEX_SHADER_EXPAND="${AM_PS2_VERTEX_SHADER_EXPAND:-}"
AUTO_VU_DIAG="${AM_PS2_VU_DIAG:-}"
AUTO_PRESENT_SAMPLE="${AM_PS2_PRESENT_SAMPLE:-}"
AUTO_RENDER_DIAG="${AM_PS2_RENDER_DIAG:-}"
AUTO_STATE_DIAG="${AM_PS2_STATE_DIAG:-}"
AUTO_GSREG_DIAG="${AM_PS2_GSREG_DIAG:-}"
AUTO_JIT_DIAG="${AM_PS2_JIT_DIAG:-}"
AUTOMATION_KEY="amethyst-automation:${APP}"
AUTOMATION_PORT="${AM_AUTOMATION_PORT:-39745}"

LOCK_DIR=/tmp/amethyst-ps2-test.lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "another run-ps2-test.sh is already running: pid=$old_pid" >&2
    exit 75
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
cleanup_lock() {
  rm -rf "$LOCK_DIR"
}
trap cleanup_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LOG_DIR="/tmp/amethyst-ps2-logs-${VERSION}"

step() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

list_app_pids() {
  local json
  json=$(mktemp "/tmp/amethyst-processes.XXXXXX.json")
  if ! xcrun devicectl device info processes \
    --device "$DEVICE" \
    --columns bundleIdentifier,pid,executablePath \
    --json-output "$json" \
    --timeout 20 >/dev/null 2>&1; then
    rm -f "$json"
    return 0
  fi
  python3 - "$json" "$APP" <<'PY'
import json
import sys

path, bundle = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)

for proc in data.get("result", {}).get("runningProcesses", []):
    text = " ".join(str(value) for value in proc.values())
    if bundle in text or "AngelAuraAmethyst" in text or "cemuios" in text:
        pid = proc.get("processIdentifier")
        if pid:
            print(pid)
PY
  rm -f "$json"
}

kill_app_processes() {
  local pid
  local pids
  pids=$(list_app_pids || true)
  for pid in $pids; do
    xcrun devicectl device process terminate \
      --device "$DEVICE" \
      --pid "$pid" \
      --kill \
      --timeout 20 >/dev/null 2>&1 || true
  done

  for _ in {1..10}; do
    pids=$(list_app_pids || true)
    [[ -z "$pids" ]] && return 0
    sleep 1
  done

  printf 'Amethyst process still alive after kill: %s\n' "$pids" >&2
  return 1
}

launch_env_json() {
  AM_TEST_ISO="$AUTO_ISO" \
  AM_TEST_RENDERER="$AUTO_RENDERER" \
  AM_TEST_CPU="$AUTO_CPU" \
  AM_TEST_IOP="$AUTO_IOP" \
  AM_TEST_VU="$AUTO_VU" \
  AM_TEST_VU0="$AUTO_VU0" \
  AM_TEST_VU1="$AUTO_VU1" \
  AM_TEST_SPEEDHACKS="$AUTO_SPEEDHACKS" \
  AM_TEST_WAIT_LOOP="$AUTO_WAIT_LOOP" \
  AM_TEST_INTC_STAT="$AUTO_INTC_STAT" \
  AM_TEST_MVU_FLAG="$AUTO_MVU_FLAG" \
  AM_TEST_INSTANT_VU1="$AUTO_INSTANT_VU1" \
  AM_TEST_VERBOSE_CORE="$AUTO_VERBOSE_CORE" \
  AM_TEST_FRAMEBUFFER_FETCH="$AUTO_FRAMEBUFFER_FETCH" \
  AM_TEST_VERTEX_SHADER_EXPAND="$AUTO_VERTEX_SHADER_EXPAND" \
  AM_TEST_VU_DIAG="$AUTO_VU_DIAG" \
  AM_TEST_PRESENT_SAMPLE="$AUTO_PRESENT_SAMPLE" \
  AM_TEST_RENDER_DIAG="$AUTO_RENDER_DIAG" \
  AM_TEST_STATE_DIAG="$AUTO_STATE_DIAG" \
  AM_TEST_GSREG_DIAG="$AUTO_GSREG_DIAG" \
  AM_TEST_JIT_DIAG="$AUTO_JIT_DIAG" \
  AM_TEST_AUTOMATION_KEY="$AUTOMATION_KEY" \
  AM_TEST_AUTOMATION_PORT="$AUTOMATION_PORT" \
  python3 - <<'PY'
import json
import os

env = {
    "AM_AUTOMATION_KEY": os.environ["AM_TEST_AUTOMATION_KEY"],
    "AM_AUTOMATION_PORT": os.environ["AM_TEST_AUTOMATION_PORT"],
    "AM_PS2_AUTO_BOOT": os.environ["AM_TEST_ISO"],
    "AM_PS2_RENDERER": os.environ["AM_TEST_RENDERER"],
}
cpu = os.environ.get("AM_TEST_CPU", "")
if cpu:
    env["AM_PS2_CPU"] = cpu
iop = os.environ.get("AM_TEST_IOP", "")
if iop:
    env["AM_PS2_IOP"] = iop
vu = os.environ.get("AM_TEST_VU", "")
if vu:
    env["AM_PS2_VU"] = vu
vu0 = os.environ.get("AM_TEST_VU0", "")
if vu0:
    env["AM_PS2_VU0"] = vu0
vu1 = os.environ.get("AM_TEST_VU1", "")
if vu1:
    env["AM_PS2_VU1"] = vu1
speedhacks = os.environ.get("AM_TEST_SPEEDHACKS", "")
if speedhacks:
    env["AM_PS2_SPEEDHACKS"] = speedhacks
wait_loop = os.environ.get("AM_TEST_WAIT_LOOP", "")
if wait_loop:
    env["AM_PS2_WAIT_LOOP"] = wait_loop
intc_stat = os.environ.get("AM_TEST_INTC_STAT", "")
if intc_stat:
    env["AM_PS2_INTC_STAT"] = intc_stat
mvu_flag = os.environ.get("AM_TEST_MVU_FLAG", "")
if mvu_flag:
    env["AM_PS2_MVU_FLAG"] = mvu_flag
instant_vu1 = os.environ.get("AM_TEST_INSTANT_VU1", "")
if instant_vu1:
    env["AM_PS2_INSTANT_VU1"] = instant_vu1
verbose_core = os.environ.get("AM_TEST_VERBOSE_CORE", "")
if verbose_core:
    env["AM_PS2_VERBOSE_CORE_LOG"] = verbose_core
framebuffer_fetch = os.environ.get("AM_TEST_FRAMEBUFFER_FETCH", "")
if framebuffer_fetch:
    env["AM_PS2_FRAMEBUFFER_FETCH"] = framebuffer_fetch
vertex_shader_expand = os.environ.get("AM_TEST_VERTEX_SHADER_EXPAND", "")
if vertex_shader_expand:
    env["AM_PS2_VERTEX_SHADER_EXPAND"] = vertex_shader_expand
vu_diag = os.environ.get("AM_TEST_VU_DIAG", "")
if vu_diag:
    env["AM_PS2_VU_DIAG"] = vu_diag
present_sample = os.environ.get("AM_TEST_PRESENT_SAMPLE", "")
if present_sample:
    env["AM_PS2_PRESENT_SAMPLE"] = present_sample
render_diag = os.environ.get("AM_TEST_RENDER_DIAG", "")
if render_diag:
    env["AM_PS2_RENDER_DIAG"] = render_diag
state_diag = os.environ.get("AM_TEST_STATE_DIAG", "")
if state_diag:
    env["AM_PS2_STATE_DIAG"] = state_diag
gsreg_diag = os.environ.get("AM_TEST_GSREG_DIAG", "")
if gsreg_diag:
    env["AM_PS2_GSREG_DIAG"] = gsreg_diag
jit_diag = os.environ.get("AM_TEST_JIT_DIAG", "")
if jit_diag:
    env["AM_PS2_JIT_DIAG"] = jit_diag
print(json.dumps(env, separators=(",", ":")))
PY
}

# Run command with hard timeout (devicectl --timeout flag is unreliable).
# Usage: with_timeout SECS cmd args...
with_timeout() {
  local secs=$1; shift
  ( "$@" ) &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -9 "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  return $rc
}

dcopy() {
  # dcopy SRC DST [TIMEOUT_SECS]
  local src=$1 dst=$2 t=${3:-20}
  local tmp
  tmp=$(mktemp "/tmp/amethyst-ps2-log.XXXXXX.json")
  if with_timeout "$t" node /Users/sb/project/Amethyst-iOS/Tools/amethystctl.mjs logs \
    --host "$DEVICE_IP" \
    --bundle "$APP" \
    --key "$AUTOMATION_KEY" \
    --path "$src" \
    --max 1048576 \
    --no-wake >"$tmp" 2>/dev/null; then
    python3 - "$tmp" "$dst" <<'PY' || true
import base64
import json
import os
import sys

payload_path, dst = sys.argv[1], sys.argv[2]
try:
    payload = json.load(open(payload_path))
except Exception:
    sys.exit(1)
if not payload.get("ok"):
    sys.exit(1)
result = payload.get("result") or {}
if isinstance(result.get("text"), str):
    content = result["text"].encode("utf-8")
elif isinstance(result.get("base64"), str):
    content = base64.b64decode(result["base64"])
else:
    content = b""
if not content:
    sys.exit(1)
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "wb") as f:
    f.write(content)
PY
  fi
  rm -f "$tmp"
}

if [[ "$SKIP_BUILD_INSTALL" == "1" ]]; then
  step "skip build/install; test installed app as $VERSION"
else
  step "build dylib"
  cmake --build /Users/sb/project/ARMSX2/build-ios-probe --target ARMSX2AmethystBridge \
    -j"$(sysctl -n hw.ncpu)" 2>&1 | grep -E "error:|undefined symbol" || true

  step "package IPA $VERSION"
  cp /Users/sb/project/ARMSX2/build-ios-probe/ios/libarmsx2_amethyst.dylib \
     /Users/sb/project/Amethyst-iOS/Natives/resources/Frameworks/libarmsx2_amethyst.dylib
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
     /Users/sb/project/Amethyst-iOS/Natives/Info.plist
  gmake -C /Users/sb/project/Amethyst-iOS -j"$(sysctl -n hw.ncpu)" package >/tmp/gmake-${VERSION}.log 2>&1
  TS=$(date +%Y%m%d%H%M%S)
  IPA=/Users/sb/project/Amethyst-iOS/artifacts/Amethyst-ps2-${VERSION}-${TS}.ipa
  cp /Users/sb/project/Amethyst-iOS/artifacts/org.angelauramc.amethyst-1.0-ios.ipa "$IPA"

  step "warm SideStore"
  xcrun devicectl device process launch --device "$DEVICE" \
    --payload-url 'sidestore://open' --activate "$SIDE" 2>&1 | tail -1

  step "install $VERSION"
  INSTALL_LOG="/tmp/sidestore-install-${VERSION}-${TS}.log"
  if ! /Users/sb/project/SideStore/scripts/sidestorectl install \
    --device "$UDID" --devicectl-device "$DEVICE" --sidestore-bundle "$SIDE" \
    --ipa "$IPA" \
    --timeout 900 --restart-sidestore --control-host "$DEVICE_IP" 2>&1 | tee "$INSTALL_LOG"; then
    exit 1
  fi
  if ! grep -qE '^(remote_status=installed|installed )' "$INSTALL_LOG"; then
    echo "SideStore did not report installed callback" >&2
    exit 1
  fi
fi

step "kill stale processes"
kill_app_processes

step "clear previous app logs"
for f in armsx2-amethyst.log automation.log metal.log stderr.log heartbeat.log vu1micro.log; do
  ios-deploy -i "$UDID" -1 "$APP" -R "Documents/ps2/Logs/$f" >/dev/null 2>&1 || true
done
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

step "launch app with fixed PS2 ISO"
LAUNCH_ENV=$(launch_env_json)
xcrun devicectl device process launch \
  --device "$DEVICE" \
  --terminate-existing \
  --environment-variables "$LAUNCH_ENV" \
  --activate "$APP" 2>&1 | tail -1
step "auto launch mode: renderer=$AUTO_RENDERER cpu=${AUTO_CPU:-default} iop=${AUTO_IOP:-default} vu=${AUTO_VU:-default} vu0=${AUTO_VU0:-default} vu1=${AUTO_VU1:-default} speedhacks=${AUTO_SPEEDHACKS:-default} waitLoop=${AUTO_WAIT_LOOP:-default} intcStat=${AUTO_INTC_STAT:-default} mvuFlag=${AUTO_MVU_FLAG:-default} instantVU1=${AUTO_INSTANT_VU1:-default} vuDiag=${AUTO_VU_DIAG:-default} presentSample=${AUTO_PRESENT_SAMPLE:-default} renderDiag=${AUTO_RENDER_DIAG:-default} stateDiag=${AUTO_STATE_DIAG:-default} gsregDiag=${AUTO_GSREG_DIAG:-default} jitDiag=${AUTO_JIT_DIAG:-default} framebufferFetch=${AUTO_FRAMEBUFFER_FETCH:-default} vertexExpand=${AUTO_VERTEX_SHADER_EXPAND:-default} iso=$AUTO_ISO"

# Event-driven wait: poll stderr.log every 4s until we see one of the terminal markers,
# OR process disappears, OR we hit MAX_WAIT.
MAX_WAIT_SEC=${MAX_WAIT_SEC:-300}
ELAPSED=0
INTERVAL=4
step "waiting for terminal marker (max=${MAX_WAIT_SEC}s)..."
LAST_LINE=""
LAST_LOG_SIZE=0
STALE_COUNT=0
SAW_RENDER=0
BROKE_STALE=0
RENDER_PATTERN="Perf frame=|AmethystRender: VSync|Merge output|frame rendered|GS.*Present"
while (( ELAPSED < MAX_WAIT_SEC )); do
  dcopy Documents/ps2/Logs/stderr.log "$LOG_DIR/stderr.log" 12
  dcopy Documents/ps2/Logs/armsx2-amethyst.log "$LOG_DIR/armsx2-amethyst.log" 12
  dcopy Documents/ps2/Logs/heartbeat.log "$LOG_DIR/heartbeat.log" 12

  if [[ -s "$LOG_DIR/stderr.log" ]]; then
    if grep -qE "MACHEXC (EXC_|signal=)|recExecute returned|AMPS2 FATAL|FATAL signal|VM stopped|frame rendered|GS.*Present" "$LOG_DIR/stderr.log"; then
      step "terminal marker reached"
      break
    fi
    LAST_LINE=$(tail -1 "$LOG_DIR/stderr.log" | head -c 160)
  fi
  if grep -qE "$RENDER_PATTERN" "$LOG_DIR/armsx2-amethyst.log" "$LOG_DIR/stderr.log" 2>/dev/null; then
    SAW_RENDER=1
  fi
  if [[ "${STOP_ON_RENDER:-0}" == "1" && -s "$LOG_DIR/armsx2-amethyst.log" ]]; then
    if grep -qE "$RENDER_PATTERN" "$LOG_DIR/armsx2-amethyst.log"; then
      step "terminal marker reached"
      break
    fi
  fi

  # Liveness: track growth across bridge, heartbeat, and stderr logs.
  # Some perf runs intentionally disable verbose bridge logs, but heartbeat
  # still proves the process is alive.
  CUR_SIZE=0
  if [[ -s "$LOG_DIR/armsx2-amethyst.log" ]]; then
    CUR_SIZE=$((CUR_SIZE + $(stat -f%z "$LOG_DIR/armsx2-amethyst.log" 2>/dev/null || echo 0)))
  fi
  if [[ -s "$LOG_DIR/heartbeat.log" ]]; then
    CUR_SIZE=$((CUR_SIZE + $(stat -f%z "$LOG_DIR/heartbeat.log" 2>/dev/null || echo 0)))
  fi
  if [[ -s "$LOG_DIR/stderr.log" ]]; then
    CUR_SIZE=$((CUR_SIZE + $(stat -f%z "$LOG_DIR/stderr.log" 2>/dev/null || echo 0)))
  fi
  if (( CUR_SIZE == LAST_LOG_SIZE )); then
    STALE_COUNT=$((STALE_COUNT + 1))
  else
    STALE_COUNT=0
    LAST_LOG_SIZE=$CUR_SIZE
  fi
  # 6 consecutive 4s stalls = 24s with no log growth → process likely dead
  if (( STALE_COUNT >= 6 )) && (( ELAPSED > 40 )); then
    if [[ "${IGNORE_STALE:-0}" != "1" ]]; then
      step "log stale ${STALE_COUNT}x at t=${ELAPSED}s — process likely dead"
      BROKE_STALE=1
      break
    fi
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
  printf '\r[wait %3ds] sz=%d stale=%d %s' "$ELAPSED" "$CUR_SIZE" "$STALE_COUNT" "${LAST_LINE:0:90}     "
done
echo

step "final log pull"
for f in armsx2-amethyst.log automation.log metal.log stderr.log heartbeat.log vu1micro.log; do
  dcopy "Documents/ps2/Logs/$f" "$LOG_DIR/$f" 25
done

OBSERVED_ISO="$(
  {
    awk '/\[PS2\] Starting game=/ { line = $0 } END { if (line) { sub(/^.*Starting game=/, "", line); sub(/ bios=.*$/, "", line); print line } }' "$LOG_DIR/automation.log" 2>/dev/null || true
    awk '/Start request iso=/ { line = $0 } END { if (line) { sub(/^.*Start request iso=/, "", line); sub(/ bios=.*$/, "", line); print line } }' "$LOG_DIR/armsx2-amethyst.log" 2>/dev/null || true
  } | awk 'NF { print; exit }' || true
)"
if [[ -z "$OBSERVED_ISO" ]]; then
  OBSERVED_ISO="UNKNOWN"
fi
step "iso check requested=$AUTO_ISO observed=$OBSERVED_ISO"

step "classify outcome"
classify() {
  local f="$LOG_DIR/stderr.log"
  if [[ "$OBSERVED_ISO" != "$AUTO_ISO" ]]; then
    echo "ISO_MISMATCH"; return
  fi
  [[ -s "$f" ]] || { echo "NO_STDERR"; return; }
  grep -qE "MACHEXC (EXC_|signal=)|AMPS2 FATAL|FATAL signal" "$f" && { echo "CAPTURED_FAULT"; return; }
  if [[ -s "$LOG_DIR/armsx2-amethyst.log" ]] && awk '
    /Diag tick=.*bootedELF=1/ { booted = 1 }
    booted && /Present sample/ {
      recent[n % 5] = ($0 ~ /nonzero=0\/4096/ && $0 ~ /hash=0x6E61DF36E5E00383/)
      n++
    }
    END {
      if (n < 5)
        exit 1
      for (i = 0; i < 5; i++)
        if (!recent[i])
          exit 1
      exit 0
    }
  ' "$LOG_DIR/armsx2-amethyst.log"; then
    echo "BLACK_SCREEN_AFTER_ELF"; return
  fi
  if grep -qE "$RENDER_PATTERN" "$LOG_DIR/armsx2-amethyst.log" "$f" 2>/dev/null; then
    if (( ELAPSED >= MAX_WAIT_SEC )); then
      echo "STABLE_RENDERED_${MAX_WAIT_SEC}s"; return
    fi
    if (( BROKE_STALE == 1 )); then
      echo "RENDERED_THEN_STALE"; return
    fi
    echo "RENDERED"; return
  fi
  grep -q "recExecute returned" "$f" && { echo "RECEXEC_RETURNED"; return; }
  grep -q "recExecute EnterRecompiledCode" "$f" && { echo "ENTERED_RECEXEC_THEN_HUNG"; return; }
  grep -q "VMManager::Execute entering" "$f" && { echo "PRE_RECEXEC_HUNG"; return; }
  if grep -q "JIT26 prepare begin #0" "$f" && ! grep -q "JIT26 prepare done  #0" "$f"; then
    echo "JIT26_PREPARE_HUNG"; return
  fi
  echo "UNKNOWN_EARLY_EXIT"
}
OUTCOME=$(classify)
step "OUTCOME: $OUTCOME"

echo "--- stderr key events ---"
grep -E "FATAL|MACHEXC|recExecute|EnterRecompiled|region kr|VMManager::Execute|VM running|JIT26.*done|HostSys::Mmap.*done" \
  "$LOG_DIR/stderr.log" 2>/dev/null | tail -20 || true

echo "--- stderr last 10 lines ---"
tail -10 "$LOG_DIR/stderr.log" 2>/dev/null || true
