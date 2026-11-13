#!/bin/zsh
# Full regression suite: build, unit tests, localization check, protocol integration tests against local
# mocks, in-app end-to-end self tests (VIGI and ONVIF recorders, in Italian/English/French, reconnection),
# 16-camera performance and idle checks. No real camera needed.
# Usage: scripts/regression.sh              everything (~25 minutes)
#        scripts/regression.sh selftest     only the in-app self tests
#        scripts/regression.sh resilience   only the account-protection scenario (~8 minutes)
#        scripts/regression.sh vigi         only the VIGI in-app self test (~5 minutes)
#        scripts/regression.sh perf         only the 16-camera performance and idle checks (~2 minutes)
#        scripts/regression.sh reopen       only: close the window, reopen it from the Dock, video back (~2 minutes)
# Report: scripts/testenv/regression-report.txt
setopt NO_NOMATCH
ROOT=${0:A:h:h}
cd $ROOT
ENV=scripts/testenv
mkdir -p $ENV
REPORT=$ENV/regression-report.txt
: > $REPORT
NPASS=0; NFAIL=0
QUICK=${1:-}
source $ROOT/scripts/sdk.sh

log() { print -r -- "$*" | tee -a $REPORT; }
ok() { NPASS=$((NPASS+1)); log "  ✔ $1"; }
ko() { NFAIL=$((NFAIL+1)); log "  ✘ $1${2:+ — $2}"; }
expect() { # name, output, regex
  if print -r -- "$2" | grep -Eq -- "$3"; then ok "$1"; else ko "$1" "$(print -r -- "$2" | tail -3 | tr '\n' ' ')"; fi
}
APPBIN=dist/Vedetta.app/Contents/MacOS/Vedetta
cleanup_app_state() {
  # Test runs use an isolated data folder and Keychain service: the user's real configuration is never touched.
  pkill -f "$APPBIN" 2>/dev/null; sleep 1
  while security delete-generic-password -s it.vedetta.devices.dev >/dev/null 2>&1; do :; done
  rm -rf ~/Library/Application\ Support/Vedetta-Dev
}

log "== Vedetta regression $(date '+%Y-%m-%d %H:%M')"

# 1. Build ---------------------------------------------------------------------------------------
log "[1] Build"
if swift build 2>&1 | tail -1 | grep -q "Build complete"; then ok "swift build"; else ko "swift build"; fi

# 2. Unit tests + localization (the CLT build system sometimes misses the Testing macro plugin: retry)
if [[ -z $QUICK ]]; then
  log "[2] Unit tests and translations"
  TESTS_BUILT=0
  for i in 1 2 3; do swift build --build-tests >/dev/null 2>&1 && { TESTS_BUILT=1; break; }; done
  # Never run a stale test binary: a test build that keeps failing is a failure, not a pass.
  if (( TESTS_BUILT )); then ok "unit tests build"; else ko "unit tests build" "$(swift build --build-tests 2>&1 | grep -m3 'error:' | tr '\n' ' ')"; fi
  UT=$( (( TESTS_BUILT )) && swift test --skip-build 2>&1 || print "unit tests not built")
  expect "unit tests" "$UT" "Test run with [0-9]+ tests? .*passed"
  if print -r -- "$UT" | grep -q "✘"; then ko "unit test failures" "$(print -r -- "$UT" | grep '✘' | head -5 | tr '\n' ' ')"; fi
  expect "translations complete (en, it, fr)" "$(python3 scripts/l10n.py --check 2>&1)" " 0 problems"
fi

# 3. Test bench ----------------------------------------------------------------------------------
log "[3] Test bench"
scripts/test-rtsp-server.sh stop >/dev/null 2>&1
pkill -f mock_nvr.py; pkill -f mock_onvif.py
scripts/test-rtsp-server.sh start >/dev/null
TUSER=$(grep "^USER=" $ENV/credentials | cut -d= -f2); TPASS=$(grep "^PASS=" $ENV/credentials | cut -d= -f2)
[[ -x $ENV/venv/bin/python ]] || { python3 -m venv $ENV/venv && $ENV/venv/bin/pip install -q cryptography; }
nohup $ENV/venv/bin/python scripts/mock_nvr.py 8443 $ENV/credentials > $ENV/mock_nvr.log 2>&1 &
nohup python3 scripts/mock_onvif.py 8081 $ENV/credentials > $ENV/mock_onvif.log 2>&1 &
for cfg in devconfig devconfig-onvif; do
  [[ -f $ENV/$cfg.json ]] && continue
  if [[ $cfg == devconfig ]]; then printf '{"address":"127.0.0.1","httpPort":8443,"rtspPort":8554,"user":"%s","pass":"%s"}' $TUSER $TPASS > $ENV/$cfg.json
  else printf '{"kind":"onvif","address":"127.0.0.1:8081","rtspPort":8554,"user":"%s","pass":"%s"}' $TUSER $TPASS > $ENV/$cfg.json; fi
done
sleep 8
export VEDETTA_USER=$TUSER VEDETTA_PASS=$TPASS
export VEDETTA_VUSER=$(grep "^VUSER=" $ENV/credentials | cut -d= -f2) VEDETTA_VPASS=$(grep "^VPASS=" $ENV/credentials | cut -d= -f2)
P=.build/debug/vedetta-probe

# 4. Protocol integration ------------------------------------------------------------------------
if [[ -z $QUICK ]]; then
  log "[4] Protocol integration"
  O=$($P rtsp rtsp://127.0.0.1:8554/live/1/1/avm 4 --record $ENV/t264.mp4 --snapshot $ENV/t264.jpg 2>&1)
  expect "RTSP H.264 1080p hardware decoding" "$O" "HW=true"
  expect "RTSP H.264 frames received" "$O" "received: ([5-9][0-9]|[1-9][0-9]{2,}) frames"
  expect "RTSP recording to MP4 (avc1 + AAC)" "$(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 $ENV/t264.mp4 2>&1 | tr '\n' ' ')" "avc1 mp4a"
  O=$($P rtsp rtsp://127.0.0.1:8554/live/2/1/avm 4 --record $ENV/t265.mp4 2>&1)
  expect "RTSP H.265 1440p" "$O" "H.265 2560x1440 HW=true"
  expect "RTSP recording to MP4 (hvc1)" "$(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 $ENV/t265.mp4 2>&1 | tr '\n' ' ')" "hvc1 mp4a"
  expect "RTSP wrong password" "$(VEDETTA_PASS=wrong $P rtsp rtsp://127.0.0.1:8554/live/1/1/avm 2 2>&1)" "Wrong user name or password"
  expect "RTSP unknown path" "$($P rtsp rtsp://127.0.0.1:8554/missing 2 2>&1)" "ERROR"
  expect "RTSP closed port" "$($P rtsp rtsp://127.0.0.1:9 2 2>&1)" "ERROR"
  O=$($P vigi 127.0.0.1:8443 2>&1)
  expect "VIGI API login + channels" "$O" "channel 3: Garage"
  expect "VIGI API calendar/segments/events" "$O" "events 24h: [1-9]"
  expect "VIGI API wrong password" "$(VEDETTA_PASS=wrong $P vigi 127.0.0.1:8443 2>&1)" "Wrong user name or password"
  expect "VIGI NVR full connection" "$($P nvr 127.0.0.1:8443 8554 2>&1)" "name=Test NVR .*channels=\[\"Entrance\", \"Garden\", \"Garage\"\] warnings=\[\]"
  O=$($P recorder 127.0.0.1:8081 2>&1)
  expect "ONVIF NVR: channels and recordings" "$O" "channel 2 Channel 2 src=VideoSource_2 rec=Rec_2"
  expect "ONVIF NVR: Profile G timeline" "$O" "today: 2 segments"
  expect "ONVIF NVR: replay" "$O" "replay frames in 3s: ([2-9][0-9]|[1-9][0-9]{2})"
  expect "ONVIF NVR wrong password" "$(VEDETTA_PASS=wrong $P recorder 127.0.0.1:8081 2>&1)" "Wrong recorder user name or password"
  for p in Streaming/Channels/102 Streaming/Channels/302; do
    ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=640x360:rate=15" -c:v h264_videotoolbox -realtime 1 -b:v 500k -g 30 -bf 0 \
      -f rtsp -rtsp_transport tcp "rtsp://$TUSER:$TPASS@127.0.0.1:8554/$p" >/dev/null 2>&1 &
  done
  sleep 4
  expect "Hikvision recorder over RTSP" "$($P brand 127.0.0.1:8554 hikvision 2>&1)" "channels=\[\"1\", \"3\"\] playback=true"
  expect "Wrong brand reported" "$($P brand 127.0.0.1:8554 dahua 2>&1)" "No camera found"
  pkill -f "Streaming/Channels"
  expect "WS-Discovery" "$($P discover x 2>&1)" "found: [0-9]+"
  nohup python3 scripts/mock_onvif.py 8082 $ENV/credentials > $ENV/mock_ptz.log 2>&1 &
  sleep 2
  expect "ONVIF PTZ (move, zoom, presets)" "$($P ptz http://127.0.0.1:8082/onvif/device_service 2>&1)" "ptz ok: .*presets=\[\"Gate\"\] after=0"
  pkill -f "mock_onvif.py 8082"
fi

# 5. App bundle ----------------------------------------------------------------------------------
log "[5] App bundle"
if scripts/build-app.sh 2>&1 | grep -q "built dist/Vedetta.app"; then ok "build Vedetta.app"; else ko "build Vedetta.app"; fi
codesign --verify --strict dist/Vedetta.app 2>/dev/null && ok "valid code signature" || ko "valid code signature"
for l in en it fr; do [[ -f dist/Vedetta.app/Contents/Resources/$l.lproj/Localizable.strings ]] && ok "bundle contains $l localization" || ko "bundle contains $l localization"; done

# 6. In-app self tests ---------------------------------------------------------------------------
run_selftest() { # name, devconfig, language, [scenario], [timeout]
  local name=$1 cfg=$2 lang=${3:-en} scenario=${4:-full} limit=${5:-600} out=$ENV/selftest-$1.json marker=$ENV/restart-$1.marker
  cleanup_app_state; rm -f $out $marker
  curl -s -X POST -d '{"reset": true}' http://127.0.0.1:8445/control >/dev/null 2>&1
  VEDETTA_DEV=1 VEDETTA_SELFTEST=1 VEDETTA_SELFTEST_SCENARIO=$scenario VEDETTA_DEV_CONFIG=$ROOT/$cfg VEDETTA_SELFTEST_OUT=$ROOT/$out \
    VEDETTA_SELFTEST_RESTART_MARKER=$ROOT/$marker VEDETTA_MOCK_CONTROL=http://127.0.0.1:8445 \
    $APPBIN -AppleLanguages "($lang)" > $ENV/app-$name.log 2>&1 &
  local pid=$! t=0 maxcpu=0 samples=0 sum=0
  while kill -0 $pid 2>/dev/null && (( t < limit )); do
    sleep 2; t=$((t+2))
    local c=$(ps -o pcpu= -p $pid 2>/dev/null | tr -d ' ')
    [[ -n $c ]] && { samples=$((samples+1)); sum=$(( sum + ${c%.*} )); (( ${c%.*} > maxcpu )) && maxcpu=${c%.*}; }
    if [[ -f $marker ]]; then
      # The self test asks for the video server to go down/up ("stop", "start") or bounce ("restart").
      local cmd=$(cat $marker 2>/dev/null); rm -f $marker
      case $cmd in
        stop) scripts/test-rtsp-server.sh stop >/dev/null 2>&1 ;;
        start) scripts/test-rtsp-server.sh start >/dev/null ;;
        *) scripts/test-rtsp-server.sh stop >/dev/null 2>&1; sleep 12; scripts/test-rtsp-server.sh start >/dev/null ;;
      esac
    fi
  done
  if kill -0 $pid 2>/dev/null; then kill $pid; ko "self-test $name" "timeout (possible freeze)"; return; fi
  if [[ ! -f $out ]]; then ko "self-test $name" "no report (crash?)"; return; fi
  python3 - "$out" "$name" <<'PY' | while IFS= read -r line; do
import json,sys
r=json.load(open(sys.argv[1]))
for x in r["results"]:
    print(("OK " if x["ok"] else "KO ")+sys.argv[2]+": "+x["name"]+" | "+x["detail"])
PY
    if [[ $line == OK* ]]; then ok "${line#OK }"; else ko "${line#KO }"; fi
  done
  log "  · CPU $name: average $(( samples ? sum / samples : 0 ))%, peak ${maxcpu}%"
}
if [[ $QUICK != resilience && $QUICK != perf ]]; then
  if [[ $QUICK == reopen ]]; then
    log "[6] In-app self test — close and reopen the window"
    run_selftest reopen-it $ENV/devconfig.json it reopen
    log "== Result: $NPASS passed, $NFAIL failed"; pkill -f mock_nvr.py; pkill -f mock_onvif.py; scripts/test-rtsp-server.sh stop >/dev/null 2>&1; exit $(( NFAIL > 0 ))
  fi
  log "[6] In-app self test — VIGI recorder (Italian, English)"
  run_selftest vigi-it $ENV/devconfig.json it
  [[ $QUICK == vigi ]] && { log "== Result: $NPASS passed, $NFAIL failed"; pkill -f mock_nvr.py; pkill -f mock_onvif.py; scripts/test-rtsp-server.sh stop >/dev/null 2>&1; exit $(( NFAIL > 0 )); }
  run_selftest vigi-en $ENV/devconfig.json en
  log "[7] In-app self test — ONVIF recorder of another brand (French)"
  run_selftest onvif-fr $ENV/devconfig-onvif.json fr
fi
if [[ $QUICK != perf ]]; then
  log "[7b] Account protection — recorder offline 2 min, refused password, locked user, sign out, switch user"
  run_selftest resilience-it $ENV/devconfig.json it resilience 1100
fi
scripts/test-rtsp-server.sh start >/dev/null 2>&1   # in case the scenario stopped it

if [[ -z $QUICK || $QUICK == perf ]]; then
  # 8. Performance: 16 channels ------------------------------------------------------------------
  log "[8] Performance with 16 cameras"
  pkill -f mock_onvif.py; sleep 1
  MOCK_CHANNELS=16 nohup python3 scripts/mock_onvif.py 8081 $ENV/credentials > $ENV/mock_onvif.log 2>&1 &
  sleep 2
  cleanup_app_state
  # Streams stay on even if other windows cover the test window (this measures load, not the pause).
  VEDETTA_DEV=1 VEDETTA_KEEP_STREAMS=1 VEDETTA_DEV_CONFIG=$ROOT/$ENV/devconfig-onvif.json $APPBIN > $ENV/app-perf.log 2>&1 &
  PID=$!
  sleep 25
  SUM=0; N=0; MAX=0
  for i in {1..10}; do c=$(ps -o pcpu= -p $PID | tr -d ' '); c=${c%.*}; SUM=$((SUM+c)); N=$((N+1)); (( c > MAX )) && MAX=$c; sleep 2; done
  RSS=$(( $(ps -o rss= -p $PID) / 1024 ))
  STREAMS=$(lsof -nP -p $PID 2>/dev/null | grep -c "127.0.0.1:8554 (ESTABLISHED)")
  log "  · 16 tiles: CPU average $((SUM/N))%, peak ${MAX}%, memory ${RSS} MB, streams ${STREAMS}"
  (( STREAMS >= 16 )) && ok "16 streams active" || ko "16 streams active" "$STREAMS"
  (( SUM/N < 60 )) && ok "CPU with 16 cameras < 60%" || ko "CPU with 16 cameras < 60%" "$((SUM/N))%"
  (( RSS < 700 )) && ok "memory with 16 cameras < 700 MB" || ko "memory with 16 cameras < 700 MB" "${RSS} MB"
  kill $PID 2>/dev/null

  # 9. Welcome screen idle -----------------------------------------------------------------------
  log "[9] Welcome screen idle"
  cleanup_app_state
  VEDETTA_DEV=1 $APPBIN > $ENV/app-welcome.log 2>&1 &
  PID=$!
  sleep 8
  R1=$(ps -o rss= -p $PID)
  SAMPLES=($(top -l 15 -s 1 -pid $PID -stats pid,cpu 2>/dev/null | awk -v p=$PID '$1==p {print int($2)}' | sort -n))
  MED=${SAMPLES[$(( (${#SAMPLES} + 1) / 2 ))]:-99}
  R2=$(ps -o rss= -p $PID)
  (( MED < 5 )) && ok "idle CPU < 5% (median ${MED}%)" || ko "idle CPU" "samples ${SAMPLES[*]}"
  (( (R2 - R1) / 1024 < 20 )) && ok "stable memory when idle" || ko "stable memory when idle" "$((R1/1024)) → $((R2/1024)) MB"
  kill $PID 2>/dev/null
fi

# Teardown -------------------------------------------------------------------------------------------
cleanup_app_state
pkill -f mock_nvr.py; pkill -f mock_onvif.py
scripts/test-rtsp-server.sh stop >/dev/null 2>&1
log "== Result: $NPASS passed, $NFAIL failed"
exit $(( NFAIL > 0 ))
