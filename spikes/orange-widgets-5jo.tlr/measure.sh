#!/bin/bash
# On the Mac under test, with the widget placed: runs a reload schedule and prints, timed, every
# sequence the widget shows, so each one can be set beside the host's "reload seq" log line.
#   measure.sh EVERY TIMES FROM RECT   RECT is the placed widget's x,y,width,height in eyes' points
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
every=$1 times=$2 from=$3 rect=$4

now() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t = time; printf "%s.%03d", strftime("%H:%M:%S", localtime $t), ($t - int $t) * 1000'; }

"$here/run.sh" reload "$every" "$times" "$from" &
host=$!
echo "$(now) schedule: $times reloads $every s apart from seq $from"
shown=unread
# The host sleeps EVERY seconds after its last reload too, so watching while it runs sees each redraw.
while [ -n "$(jobs -rp)" ]; do
  seq=$(eyes read --rect "$rect" --limit 10 | awk 'match($0, /SEQ [0-9]+/) && !found { found = 1; print substr($0, RSTART, RLENGTH) }')
  if [ "$seq" != "$shown" ]; then
    echo "$(now) screen: ${seq:-no SEQ}"
    shown=$seq
  fi
done
wait "$host"
