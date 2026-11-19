#!/usr/bin/env bash
# run on the norns: ssh we@norns.local 'bash -s' < tools/test_engine.sh [seconds]
# starts tx6d.py in a scratch dir, records a short take, splits it, cleans up.
SECS=${1:-4}
L=~/dust/code/tx6rec/lib
SH=/dev/shm/tx6t; ST=/tmp/tx6t/state; T=/tmp/tx6t/takes
stop_engine() { [ -f $SH/pid ] && kill "$(cat $SH/pid)" 2>/dev/null; sleep 0.3; }
stop_engine; rm -rf $SH /tmp/tx6t; mkdir -p $ST
printf 'name=test\nmode1=stereo\nmode2=mono\nmode3=off\nmode4=off\nmode5=off\nmode6=2xmono\nskip=1\n' > $ST/settings
setsid python3 $L/tx6d.py $SH $ST $L/rec.sh >/dev/null 2>&1 </dev/null &
sleep 1.5
echo "--- levels at rest:"; for i in 1 2 3; do cat $SH/levels; sleep 0.3; done
echo "--- status: $(tr '\n' ' ' < $SH/status)"
echo "$T/test/test_take.raw" > $SH/rec
sleep "$SECS"; touch $SH/hb
echo "--- recording: $(tr '\n' ' ' < $SH/status)"
rm $SH/rec
for i in $(seq 60); do grep -q '^state=done' $SH/split 2>/dev/null && break; sleep 0.25; done
echo "--- split: $(tr '\n' ' ' < $SH/split)"
for f in $T/test/*.wav; do echo "$(basename $f) $(soxi -c $f)ch $(soxi -D $f)s"; done
echo "--- log:"; cat $ST/log
stop_engine; rm -rf $SH /tmp/tx6t
