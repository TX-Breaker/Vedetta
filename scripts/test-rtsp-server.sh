#!/bin/zsh
# Local RTSP test bench: mediamtx (Digest auth) + ffmpeg test streams that mimic the VIGI NVR URL layout.
# Usage: scripts/test-rtsp-server.sh start|stop
set -e
DIR=${0:A:h}/testenv
mkdir -p $DIR
CRED=$DIR/credentials
if [[ ! -f $CRED ]]; then
  echo "USER=vedetta" > $CRED
  echo "PASS=$(openssl rand -hex 8)" >> $CRED
fi
source $CRED
case "$1" in
start)
  cat > $DIR/mediamtx.yml <<YML
logLevel: warn
rtspAddress: :8554
rtspTransports: [tcp]
rtspAuthMethods: [digest]
rtmp: no
hls: no
webrtc: no
srt: no
api: no
metrics: no
pprof: no
playback: no
authMethod: internal
authInternalUsers:
  - user: $USER
    pass: $PASS
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: publish
      - action: read
paths:
  all_others:
YML
  ( cd $DIR && mediamtx $DIR/mediamtx.yml > $DIR/mediamtx.log 2>&1 & echo $! > $DIR/mediamtx.pid )
  sleep 1
  U="rtsp://$USER:$PASS@127.0.0.1:8554"
  pub() { # path size fps vcodec acodec
    ffmpeg -hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=${2}:rate=${3}" -f lavfi -i "sine=frequency=440:sample_rate=8000" \
      -c:v $4 -realtime 1 -b:v 2M -g $(( $3 * 2 )) -bf 0 -c:a $5 -f rtsp -rtsp_transport tcp "$U/$1" > $DIR/ffmpeg-${1//\//_}.log 2>&1 &
    echo $! >> $DIR/ffmpeg.pids
  }
  : > $DIR/ffmpeg.pids
  pub live/1/1/avm 1920x1080 25 h264_videotoolbox pcm_mulaw
  pub live/1/2/avm 640x360 15 h264_videotoolbox pcm_mulaw
  pub live/2/1/avm 2560x1440 20 hevc_videotoolbox aac
  pub live/2/2/avm 640x360 15 hevc_videotoolbox aac
  pub replay/1/1/avm 1920x1080 25 h264_videotoolbox pcm_alaw
  pub replay/2/1/avm 1280x720 25 hevc_videotoolbox aac
  sleep 2
  echo "started"
  ;;
stop)
  # Only kill real PIDs: an empty or "0" entry would signal the whole process group.
  for f in $DIR/ffmpeg.pids $DIR/mediamtx.pid; do
    [[ -f $f ]] || continue
    for pid in $(cat $f); do [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) && kill $pid 2>/dev/null; done
  done
  true
  rm -f $DIR/*.pid $DIR/ffmpeg.pids
  echo "stopped"
  ;;
esac
