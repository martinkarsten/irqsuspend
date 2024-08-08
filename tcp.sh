#!/bin/bash
# set -x # print values
# set -v # print variables

prevfile=$HOME/.tcp.sh.previous.$HOSTNAME

[ "$1" = "raw" ] && raw=true || raw=false

# read previous counters, if needed
$raw || {
  touch $prevfile
	sentprev=$((grep -F sent: $prevfile || echo ":0")|cut -f2 -d:)
	retransprev=$((grep -F retrans: $prevfile || echo ":0")|cut -f2 -d:)
	timeoutprev=$((grep -F timeout: $prevfile || echo ":0")|cut -f2 -d:)
}

# current counters
sent=$((netstat -s|grep -F "segments sen" || echo 0)|awk '{print $1}')
retrans=$((netstat -s|grep -F "segments retrans" || echo 0)|awk '{print $1}')
timeout=$(netstat -s|grep -F "TCPTimeouts"|awk '{print $2}')
[ $timeout ] || timeout=$((netstat -s|grep -F "other TCP timeouts" || echo 0)|awk '{print $1}')

$raw || {
	echo "sent:$sent" > $prevfile
	echo "retrans:$retrans" >> $prevfile
	echo "timeout:$timeout" >> $prevfile
	sent=$(expr $sent - $sentprev)
	retrans=$(expr $retrans - $retransprev)
	timeout=$(expr $timeout - $timeoutprev)
}

[ $sent -gt 0 ] && loss=$(echo $timeout $sent|awk '{printf "%7.3f\n", 100 * $1 / $2}') || loss=0

[ $(($sent + $retrans + $timeout)) -gt 0 ] && printf "sent %10d | retrans %10d | timeout %10d | loss rate %7.3f%%\n" $sent $retrans $timeout $loss

exit 0
