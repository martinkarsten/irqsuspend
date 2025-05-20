#!/bin/bash

function error() {
  echo
  echo ERROR: "$*"
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
  echo "-p ev1,ev2,...     perf events"
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
opt_events="cycles,instructions"
unset arg_qps
TESTCASES=$(show_testcases)
while getopts "bc:fhn:p:q:t:" option; do
case $option in
	b) opt_build=true;;
	c) arg_cores=${OPTARG};;
	f) opt_flamegraph=true;;
	h) opt_ht=true;;
	n) arg_conns=${OPTARG};;
	p) opt_events=${OPTARG};;
	q) arg_qps=$(echo ${OPTARG}|tr , ' ');;
	t) TESTCASES=$(echo ${OPTARG}|tr , ' ');;
	*) usage;;
esac; done
shift $(($OPTIND - 1))

# set a default
COALESCEd="na na na na na na na na na na na na"
COALESCE1="na na na na na na na na na na na na"
COALESCE0="na na na na na na na na na na na na"

# client & server settings based on server name
[ $# -gt 0 ] || usage
case $1 in
husky02|red01|red01vm|tilly01|mlx4|tilly02|node10)
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

qdef=max

startup() {
	qdef=$(ssh $SERVER ./irq.sh $IFACE clean getq)
	[ -z "$qdef" ] && error problem with running irq.sh on $SERVER
	tdef=$(ssh $SERVER ./setup.sh turboget)
}

cleanup() {
	pdsh -w $DRIVER,$CLIENTS killall -q -9 mutilate 2>/dev/null
	ssh $SERVER killall -q -9 memcached 2>/dev/null
	ssh $SERVER sudo killall -q -9 bpftrace 2>/dev/null
	ssh $SERVER ./irq.sh $IFACE setq $qdef
	ssh $SERVER ./irq.sh $IFACE setirq1 all 0 $qdef setcoalesce $COALESCEd setpoll 0 0 0
	[ -z "$tdef" ] || ssh $SERVER ./setup.sh turboset $tdef
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
	$(dirname $0)/build.sh $SERVER || exit 1
} || {
	$(dirname $0)/build.sh -w $SERVER
}

# copy script files
echo "copying scripts to server and clients"
dir=$(dirname $0)
scp $dir/{irq,setup}.sh $SERVER: >/dev/null 2>&1 &
for h in $DRIVER $(echo $CLIENTS|tr , ' '); do scp $dir/tcp.sh $h: >/dev/null 2>&1 & done
wait

startup
trap "echo cleaning up; cleanup; check_last_file; wait" EXIT
trap "exit 1" SIGHUP SIGINT SIGQUIT SIGTERM

[ "$RUNS" = "clean" ] && exit 0 # exit trap cleans up
echo "cleaning up"; cleanup

ssh $SERVER ./setup.sh turboset 100 100 1

# loop over test cases
for ((run=0;run<$RUNS;run++)); do
[ -f runs ] && [ $(cat runs) -lt $run ] && exit 0
for qps in $QPS; do
for tc in $TESTCASES; do
	file=$qps-$tc-$run; echo && echo -n "***** PREPARING $file "
	[ -f mutilate-$file.out ] && { echo "already done"; continue; }
	conns=$CONNS; cpus=$CORES
	case "$tc" in # testcases start
		base)       CL=d; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		base1c)     CL=x; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		defer10)    CL=d; HTSPLIT=true;  POLLVAR="   10000 100        0"; MEMVAR="";;
		defer20)    CL=d; HTSPLIT=true;  POLLVAR="   20000 100        0"; MEMVAR="";;
		defer50)    CL=d; HTSPLIT=true;  POLLVAR="   50000 100        0"; MEMVAR="";;
		defer200)   CL=d; HTSPLIT=true;  POLLVAR="  200000 100        0"; MEMVAR="";;
		napibusy)   CL=d; HTSPLIT=false; POLLVAR="  200000 100        0"; MEMVAR="_MP_Usecs=64   _MP_Budget=64 _MP_Prefer=1";;
		fullbusy)   CL=d; HTSPLIT=false; POLLVAR=" 5000000 100        0"; MEMVAR="_MP_Usecs=1000 _MP_Budget=64 _MP_Prefer=1"; MEMSPEC+=" -y";;
		suspend0)   CL=d; HTSPLIT=false; POLLVAR="       0   0 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend1)   CL=d; HTSPLIT=false; POLLVAR="    1000   1 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend10)  CL=d; HTSPLIT=false; POLLVAR="   10000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend20)  CL=d; HTSPLIT=false; POLLVAR="   20000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend50)  CL=d; HTSPLIT=false; POLLVAR="   50000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend200) CL=d; HTSPLIT=false; POLLVAR="  200000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
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
	eval COALESCING=\$COALESCE$CL
	ssh $SERVER NDCLI=\"$NDCLI\" ./irq.sh $IFACE setq $irqs setirqN $OTHER 0 0 setirq1 $irqcpuset 0 $irqs setcoalesce $COALESCING setpoll $POLLVAR show > setup-$file.out
	printf "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC\n\n" > memcached-$file.out
	ssh -f $SERVER "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC"
	echo -n "SERVER "; timeout 30s ssh $SERVER "while ! socat /dev/null TCP:localhost:11211 2>/dev/null; do sleep 1; done" || echo "SERVER FAILED" >> memcached-$file.out
	pdsh -w $CLIENTS $MUTILATE -A 2>/dev/null &
	echo -n "AGENTS "; timeout 30s pdsh -w $CLIENTS "while ! socat /dev/null TCP:localhost:5556 2>/dev/null; do sleep 1; done" || echo "AGENTS FAILED" >> memcached-$file.out
	echo -n "LOAD "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS --loadonly || echo "LOAD FAILED" >> memcached-$file.out
	echo -n "WARM "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 10 >/dev/null 2>&1 || echo "WARMUP FAILED" >> memcached-$file.out
	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_poll { @[args->work] = count(); }"' > poll-$file.out
#	ssh -f $SERVER 'sudo bpftrace -e "tracepoint:napi:napi_debug { @[args->op,args->napi_id,args->cpu,args->data] = count(); }"' > napi-$file.out
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh >/dev/null
	ssh $SERVER sudo sh -c "'echo hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
	ssh -f $SERVER "sleep 12; taskset -c $observer sar -P $allcpuset -u ALL 1 10" > sar-$file.out
	$opt_flamegraph && {
		ssh -f $SERVER "sleep 12; taskset -c $observer $PERF record -C $allcpuset -F 99 -g -o perf.data -- sleep 10 >/dev/null"
	} || {
		ssh -f $SERVER "sleep 12; taskset -c $observer $PERF stat -C $allcpuset -e $opt_events --no-big-num -- sleep 10 2>&1" > perf-$file.out
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
