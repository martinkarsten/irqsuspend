#!/bin/bash

function error() {
	echo
  echo ERROR: $*
  echo
  exit 1
}

function usage() {
  echo "$(basename $0) [cp] [options] <server> [<# runs> | clean]"
  echo "Options:"
  echo "-b                 build kernel first"
  echo "-c num             server cpus"
  echo "-f                 create flamegraph"
  echo "-h                 hyperthread mode"
  echo "-n num             connections per mutilate thread"
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
opt_build=false
unset arg_cores
opt_flamegraph=false
opt_ht=false
unset arg_conns
unset arg_qps
TESTCASES=$(show_testcases)
while getopts "bc:fhn:q:t:" option; do
case $option in
	b) opt_build=true;;
	c) arg_cores=${OPTARG};;
	f) opt_flamegraph=true;;
	h) opt_ht=true;;
	n) arg_conns=${OPTARG};;
	q) arg_qps=$(echo ${OPTARG}|tr , ' ');;
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

# process options and arguments
$opt_ht && [ $HTBASE -eq 0 ] && error no hyperthreading on $SERVER

[[ $arg_qps ]] && QPS=$arg_qps || QPS="0 $QPS"

[[ $arg_cores ]] && [ $arg_cores -le $MAXCORES ] && CORES=$arg_cores || CORES=$MAXCORES

[[ $arg_conns ]] && CONNS=$arg_conns || CONNS=20

[ $# -gt 0 ] && { RUNS=$1; shift; } || RUNS=1

[ $# -gt 0 ] && usage

# print summary
echo "server: $SERVER; driver: $DRIVER; clients: $CLIENTS"
echo "tests: $TESTCASES"
echo "runs: $RUNS; rates: $QPS"
echo "cores: $CORES; ht: $opt_ht; conns: $CONNS"

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
$opt_build && {
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

trap "echo cleaning up; cleanup; check_last_file; wait" EXIT
trap "exit 1" SIGHUP SIGINT SIGQUIT SIGTERM

[ "$RUNS" = "clean" ] && exit 0 # exit trap cleans up
echo "cleaning up"; cleanup

# loop over test cases
for ((run=0;run<$RUNS;run++)); do
[ -f runs ] && [ $(cat runs) -lt $run ] && exit 0
for qps in $QPS; do
for tc in $TESTCASES; do
	file=$qps-$tc-$run; echo && echo -n "***** PREPARING $file "
	[ -f mutilate-$file.out ] && { echo "already done"; continue; }
	conns=$CONNS; cpus=$CORES
	case "$tc" in # testcases start
		base)       HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		busy)       HTSPLIT=false; POLLVAR="  200000 100        0"; MEMVAR="_MP_Usecs=64   _MP_Budget=64 _MP_Prefer=1";;
		fullbusy)   HTSPLIT=false; POLLVAR=" 5000000 100        0"; MEMVAR="_MP_Usecs=1000 _MP_Budget=64 _MP_Prefer=1"; MEMSPEC+=" -y";;
		defer10)    HTSPLIT=true;  POLLVAR="   10000 100        0"; MEMVAR="";;
		defer20)    HTSPLIT=true;  POLLVAR="   20000 100        0"; MEMVAR="";;
		defer50)    HTSPLIT=true;  POLLVAR="   50000 100        0"; MEMVAR="";;
		defer200)   HTSPLIT=true;  POLLVAR="  200000 100        0"; MEMVAR="";;
		defer2000)  HTSPLIT=true;  POLLVAR=" 2000000 100        0"; MEMVAR="";;
		suspend10)  HTSPLIT=false; POLLVAR="   10000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend20)  HTSPLIT=false; POLLVAR="   20000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend50)  HTSPLIT=false; POLLVAR="   50000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		suspend200) HTSPLIT=false; POLLVAR="  200000 100 20000000"; MEMVAR="_MP_Usecs=0  _MP_Budget=64 _MP_Prefer=1";;
		*) echo UNKNOWN TEST CASE $tc; continue;;
	esac          # testcases end
	$opt_ht && {
		base1=$BASECORE
		base2=$(($BASECORE + $HTBASE))
		top1=$(($base1 + $cpus / 2 - 1))
		top2=$(($base2 + $cpus / 2 - 1))
		$HTSPLIT && {
			((cpus/=2))
			runcpuset=$base1-$top1
			irqcpuset=$base2-$top2
			allcpuset=$runcpuset,$irqcpuset
			observer=$cpus
			irqs=$cpus
		} || {
			runcpuset=$base1-$top1,$base2-$top2
			irqcpuset=$runcpuset
			allcpuset=$runcpuset
			observer=$(($cpus / 2))
			irqs=$cpus
		}
	} || {
		base=$BASECORE
		top=$(($base + $cpus - 1));
		runcpuset=$base-$top
		irqcpuset=$runcpuset
		allcpuset=$runcpuset
		observer=$cpus
		irqs=$cpus
	}
	MEMSPEC="-t $cpus -N $cpus -b 16384 -c 32768 -m 10240 -o hashpower=24,no_lru_maintainer,no_lru_crawler"
	MUTSPEC="-c $conns -q $qps -d 1 -u 0.03"
	ssh $SERVER ./irq.sh $IFACE setq $irqs setirqN $OTHER 0 0 setirq1 $irqcpuset 0 $irqs setpoll $POLLVAR show > setup-$file.out
	printf "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC\n\n" > memcached-$file.out
	ssh -f $SERVER "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC"
	(pdsh -w $CLIENTS $MUTILATE -A 2>/dev/null &); sleep 1
	echo -n "LOAD "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS --loadonly
	echo -n "WARM "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 10 >/dev/null 2>&1 # warmup
	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_poll { @[args->work] = count(); }"' > poll-$file.out
#	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_debug { @[args->op,args->napi_id,args->cpu,args->data] = count(); }"' > napi-$file.out
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh >/dev/null
	ssh $SERVER sudo sh -c "'echo hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
	ssh -f $SERVER "sleep 12; taskset -c $observer sar -P $allcpuset -u ALL 1 10" > sar-$file.out
	$opt_flamegraph && {
		ssh -f $SERVER "sleep 12; taskset -c $observer $PERF record -C $allcpuset -F 99 -g -o perf.data -- sleep 10 >/dev/null"
	} || {
		ssh -f $SERVER "sleep 12; taskset -c $observer $PERF stat -C $allcpuset -e cycles,instructions --no-big-num -- sleep 10 2>&1" > perf-$file.out
	}
	ssh $SERVER ./irq.sh $IFACE count > /dev/null
	printf "$MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 30\n\n" >> memcached-$file.out
	echo "RUN "; timeout 60s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 30 | tee mutilate-$file.out # experiment
	ssh $SERVER ./irq.sh $IFACE count | tee irq-$file.out
	ssh $SERVER cat /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/hist|grep -F mc-worker > epoll-$file.out
	ssh $SERVER sudo sh -c "'echo \!hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh | tee tcp-$file.out
	ssh $SERVER "(echo stats;sleep 1)|telnet localhost 11211" > stats-$file.out
	killproc; kill -9 $(jobs -p) 2>/dev/null
	$opt_flamegraph && {
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
