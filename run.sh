#!/bin/bash

function error() {
  echo $*
  exit 1
}

function usage() {
  echo "$(basename $0) [cp] [options] <server> [<# runs> | clean]"
  echo "Options:"
  echo "-b                 build kernel first"
  echo "-f                 create flamegraph"
  echo "-q qps1,qps2,...   load rates"
  echo "-t test1,test2,... test cases"
  exit 0
}

function show_testcases() {
	case_start=$(grep -Fn "testcases start" $0|tail -1|cut -f1 -d:)
	case_end=$(grep -Fn "testcases end" $0|tail -1|cut -f1 -d:)
	case_start=$(($case_start+1))
	case_end=$(($case_end-1))
	cases_available=$(sed -n "${case_start},${case_end}p" $0 | sed 's/#.*//' | tr '\n' ' ' | sed 's/;;/\n/g' | sed 's/).*//;s/[[:blank:]]*//' | grep -Fvw \*)
	echo $cases_available
}

# copy scripts into local directory
[ "$1" = "cp" ] && {
	[ -f $(basename $0) ] && {
		error scripts already present in this directory
	}
	cp $(dirname $0)/*.sh .
	shift
	exec ./run.sh $*
}

# command-line options: runs, qps, test cases
BUILD=false
FLAMEGRAPH=false
unset REQUESTED_QPS
TESTCASES=$(show_testcases)
while getopts "bfq:t:" option; do
case $option in
	b) BUILD=true;;
	f) FLAMEGRAPH=true;;
	q) REQUESTED_QPS=$(echo ${OPTARG}|tr , ' ');;
	t) TESTCASES=$(echo ${OPTARG}|tr , ' ');;
	*) usage;;
esac; done
shift $(($OPTIND - 1))

# client & server settings based on server name
[ $# -gt 0 ] || usage
case $1 in
red01|red01vm|tilly01|tilly02|node10)
	hostfile=$(dirname $0)/hostspec.martin.sh;;
*)
	hostfile=$(dirname $0)/hostspec.$1.sh;;
esac
[ -f $hostfile ] && source $hostfile || error cannot find $hostfile
shift

[ $REQUESTED_QPS ] && QPS=$REQUESTED_QPS || QPS="0 $QPS"

[ $# -gt 0 ] && { RUNS=$1; shift; } || RUNS=1

[ $# -gt 0 ] && usage

echo "server: $SERVER"
echo "driver: $DRIVER"
echo "clients: $CLIENTS"
echo "tests: $TESTCASES"
echo "rates: $QPS"
echo "runs: $RUNS"

[ "$RUNS" = "show" ] && exit 0

# helper routines
killproc() {
	pdsh -w $DRIVER,$CLIENTS killall -q mutilate
	ssh $SERVER killall -q memcached
	ssh $SERVER sudo killall -q bpftrace
}

cleanup() {
	pdsh -w $DRIVER,$CLIENTS killall -q -9 mutilate 2>/dev/null
	ssh $SERVER killall -q -9 memcached 2>/dev/null
	ssh $SERVER sudo killall -q -9 bpftrace 2>/dev/null
	ssh $SERVER ./irq.sh $IFACE setpoll 0 0 0
}

check_last_file() {
	[ $file ] || return
	[ -s mutilate-$file.out ] || rm *-$file.out
}

# basic setup
AGENTS=$(for m in $(echo $CLIENTS|tr , ' '); do echo -n " -a $m";done)
MUTARGS="-s $SERVER_IP -K fb_key -V fb_value -i fb_ia -r 1000000"
MUTILATE+=" -T $MUTCORES"

# build kernel, if requested
$BUILD && {
	$(dirname $0)/build.sh full $SERVER || exit 1
} || {
	echo "waiting for server"
	until ssh -t -oPasswordAuthentication=no $SERVER ./setup.sh 2>/dev/null; do sleep 3; done
}

# copy script files
echo "copying scripts to server and clients"
dir=$(dirname $0)
scp $dir/irq.sh $SERVER: >/dev/null 2>&1 &
for h in $DRIVER $(echo $CLIENTS|tr , ' '); do scp $dir/tcp.sh $h: >/dev/null 2>&1 & done
wait

trap "echo cleaning up; cleanup; check_last_file" EXIT
trap "exit 1" SIGHUP SIGINT SIGQUIT SIGTERM

[ "$RUNS" = "clean" ] && exit 0 # exit trap cleans up
echo "cleaning up"; cleanup

# loop over runs and test cases (could loop over cpus and conns as well)
conns=20; cpus=$MAXCORES; topcpu=$(expr $BASECORE + $cpus - 1);
for ((run=0;run<$RUNS;run++)); do
[ -f runs ] && [ $(cat runs) -lt $run ] && exit 0
for qps in $QPS; do
for tc in $TESTCASES; do
	file=$qps-$tc-$run; echo && echo -n "***** PREPARING $file "
	[ -f mutilate-$file.out ] && { echo "already done"; continue; }
	MEMSPEC="-t $cpus -N $cpus -b 16384 -c 32768 -m 10240 -o hashpower=24,no_lru_maintainer,no_lru_crawler"
	MUTSPEC="-c $conns -q $qps -d 1 -u 0.03"
	case "$tc" in # testcases start
		base)       POLLVAR="       0   0        0"; MEMVAR="";;
		busy)       POLLVAR="  200000 100        0"; MEMVAR="_MP_Usecs=64   _MP_Budget=64 _MP_Prefer=1";;
		fullbusy)   POLLVAR=" 5000000 100        0"; MEMVAR="_MP_Usecs=1000 _MP_Budget=64 _MP_Prefer=1"; MEMSPEC+=" -y";;
		defer10)    POLLVAR="   10000 100        0"; MEMVAR="";;
		defer20)    POLLVAR="   20000 100        0"; MEMVAR="";;
		defer50)    POLLVAR="   50000 100        0"; MEMVAR="";;
		defer200)   POLLVAR="  200000 100        0"; MEMVAR="";;
		defer2000)  POLLVAR=" 2000000 100        0"; MEMVAR="";;
		suspend10)  POLLVAR="   10000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend20)  POLLVAR="   20000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend50)  POLLVAR="   50000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend200) POLLVAR="  200000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		*) echo UNKNOWN TEST CASE $tc; continue;;
	esac          # testcases end
	ssh $SERVER ./irq.sh $IFACE setirq all $OTHER setirq linear $BASECORE $topcpu setpoll $POLLVAR show > setup-$file.out
	ssh -f $SERVER "$MEMVAR taskset -c $BASECORE-$topcpu $MEMCACHED $MEMSPEC"
	(pdsh -w $CLIENTS $MUTILATE -A 2>/dev/null &); sleep 1
	echo -n "LOAD "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS --loadonly
	echo -n "WARM "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 10 >/dev/null 2>&1 # warmup
	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_poll { @[args->work] = count(); }"' > poll-$file.out
#	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_debug { @[args->op,args->napi_id,args->cpu,args->data] = count(); }"' > napi-$file.out
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh >/dev/null
	ssh $SERVER sudo sh -c "'echo hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
	ssh -f $SERVER "sleep 12; taskset -c $cpus sar -P $BASECORE-$topcpu -u ALL 1 10" > sar-$file.out
	$FLAMEGRAPH && {
		ssh -f $SERVER "sleep 12; taskset -c $cpus $PERF record -C $BASECORE-$topcpu -F 99 -g -o perf.data -- sleep 10 >/dev/null"
	} || {
		ssh -f $SERVER "sleep 12; taskset -c $cpus $PERF stat -C $BASECORE-$topcpu -e cycles,instructions --no-big-num -- sleep 10 2>&1" > perf-$file.out
	}
	ssh $SERVER ./irq.sh $IFACE count > /dev/null
	echo "RUN "; timeout 60s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 30 | tee mutilate-$file.out # experiment
	ssh $SERVER ./irq.sh $IFACE count | tee irq-$file.out
	ssh $SERVER cat /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/hist|grep -F mc-worker > epoll-$file.out
	ssh $SERVER sudo sh -c "'echo \!hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh | tee tcp-$file.out
	ssh $SERVER "(echo stats;sleep 1)|telnet localhost 11211" > stats-$file.out
	killproc; kill -9 $(jobs -p) 2>/dev/null
	$FLAMEGRAPH && {
		# need ssh -t here, otherwise 'perf script' assumes that stdin is a file and won't run
		ssh -t $SERVER "$PERF script >out.perf && $FGDIR/stackcollapse-perf.pl out.perf >out.folded && $FGDIR/flamegraph.pl out.folded >flamegraph.svg"
		scp $SERVER:flamegraph.svg flamegraph-$file.svg && ssh $SERVER "rm -f perf.data out.perf out.folded flamegraph.svg"
	}
done; done; done

exit 0


# set coalescing parameters, e.g., for mlx5
COALESCEd=" on  on  8 128 na na  8 128 na na  on off" # default
COALESCE1="off off  8 128 na na  8 128 na na off off" # Adaptive RX/TX off, CQE mode RX off
COALESCE0="off off  0   1 na na  0   1 na na off off" # all coalescing off
CL=d
eval COALESCING=\$COALESCE$CL
ssh $SERVER ./irq.sh setcoalesce $COALESCING
ssh $SERVER ./irq.sh setcoalesce $COALESCEd # reset to default

# default coalescing parameters for mlx4
COALESCEd=" on na 16 44 na na 16 16 na 256 na na" # default
