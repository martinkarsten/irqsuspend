#!/bin/bash

source $(dirname $0)/util.sh

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

# copy scripts into local directory
[ "$1" = "cp" ] && {
	[ -f $(basename $0) ] && ERROR scripts already present in this directory
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
TESTCASES=$(show_cases testcases $0)
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
COALESCEx="na na na na na na na na na na na na"

# client & server settings based on server name
[ $# -gt 0 ] || usage
case $1 in
husky10|red01|red01vm|tilly01|mlx4|tilly02|node10)
	hostfile=$(dirname $0)/hostspec.martin.sh;;
*)
	hostfile=$(dirname $0)/hostspec.$1.sh;;
esac
[ -f $hostfile ] && source $hostfile || ERROR cannot find $hostfile
shift

# process options and arguments
$opt_ht && [ $HTBASE -eq 0 ] && ERROR no hyperthreading on $SERVER

[[ $arg_qps ]] && QPS=$arg_qps || QPS="0 $QPS"

[[ $arg_cores ]] && [ $arg_cores -le $MAXCORES ] && CORES=$arg_cores || CORES=$MAXCORES

[[ $arg_conns ]] && CONNS=$arg_conns || CONNS=24

[ $# -gt 0 ] && { RUNS=$1; shift; } || RUNS=1

[ $# -gt 0 ] && usage

# print summary
echo "server: $SERVER; driver: $DRIVER; clients: $CLIENTS"
echo "tests: $TESTCASES"
echo "runs: $RUNS; rates: $QPS"
echo "cores: $CORES; ht: $opt_ht; conns: $CONNS"

[ "$RUNS" = "show" ] && exit 0

cleanup() {
	pdsh -w $DRIVER,$CLIENTS killall -q -9 mutilate 2>/dev/null
	ssh $SERVER killall -q -9 memcached 2>/dev/null
	bpftrace_kill;
}

check_last_file() {
	[ $file ] || return
	[ -s mutilate-$file.out ] || rm -f *-$file.out
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
scp $dir/{irq,setup,util}.sh $SERVER: >/dev/null 2>&1 &
for h in $DRIVER $(echo $CLIENTS|tr , ' '); do scp $dir/tcp.sh $h: >/dev/null 2>&1 & done
wait

trap "echo cleaning up; cleanup; wait; check_last_file" EXIT
trap "exit 1" SIGHUP SIGINT SIGQUIT SIGTERM

[ "$RUNS" = "clean" ] && exit 0 # exit trap cleans up
echo "cleaning up"; cleanup

ssh $SERVER ./setup.sh
ssh $SERVER ./setup.sh -c $BASECORE-$(($BASECORE + $MAXCORES - 1))
ssh $SERVER ./irq.sh $IFACE clean

# loop over test cases
for ((run=0;run<$RUNS;run++)); do
[ -f runs ] && [ $run -ge $(cat runs) ] && exit 0
for qps in $QPS; do
for tc in $TESTCASES; do
	file=$qps-$tc-$run; echo && echo -n "***** PREPARING $file "
	[ -f mutilate-$file.out ] && { echo "already done"; continue; }
	conns=$CONNS; cpus=$CORES
	case "$tc" in # testcases case_start
		base)       CL=d; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		base1c)     CL=x; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		defer20)    CL=d; HTSPLIT=true;  POLLVAR="   20000 100        0"; MEMVAR="";;
		defer200)   CL=d; HTSPLIT=true;  POLLVAR="  200000 100        0"; MEMVAR="";;
		napibusy)   CL=d; HTSPLIT=false; POLLVAR="  200000 100        0"; MEMVAR="_MP_Usecs=64   _MP_Budget=64 _MP_Prefer=1";;
		fullbusy)   CL=d; HTSPLIT=false; POLLVAR=" 5000000 100        0"; MEMVAR="_MP_Usecs=1000 _MP_Budget=64 _MP_Prefer=1"; MEMSPEC+=" -y";;
		suspend10)  CL=d; HTSPLIT=false; POLLVAR="   10000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend20)  CL=d; HTSPLIT=false; POLLVAR="   20000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		*) echo UNKNOWN TEST CASE $tc; continue;;
	esac          # testcases esac_end
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
	ssh $SERVER NDCLI=\"$NDCLI\" ./irq.sh -p $IFACE setq $irqs setirqN $OTHER 0 0 setirq1 $irqcpuset 0 $irqs setcoalesce $COALESCING setpoll $POLLVAR show > setup-$file.out
	printf "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC\n\n" > memcached-$file.out
	printf "SERVER "; ssh -f $SERVER "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC"
	printf "AGENTS "; pdsh -w $CLIENTS $MUTILATE -A 2>/dev/null &
	check_port 11211 $SERVER || echo "SERVER FAILED" | tee -a memcached-$file.out
	check_port 5556 $CLIENTS || echo "AGENTS FAILED" | tee -a memcached-$file.out
	printf "LOAD "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS --loadonly || echo "LOAD FAILED" >> memcached-$file.out
	printf "WARM "; timeout 30s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 10 >/dev/null 2>&1 || echo "WARMUP FAILED" >> memcached-$file.out
	tcptrace_start
	bpftrace_start
	polltrace_start
	sartrace_run 10 10
	$opt_flamegraph && flamegraph_start 10 10 || perfevent_run 10 10
	irqtrace_start
	printf "$MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 30\n\n" >> memcached-$file.out
	printf "RUN\n"; timeout 60s ssh $DRIVER $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t 30 | tee mutilate-$file.out # experiment
	irqtrace_stop
	polltrace_stop
	bpftrace_stop
	tcptrace_stop
	memcached_stats
	pdsh -w $DRIVER,$CLIENTS killall -q mutilate
	ssh $SERVER killall -q memcached
	kill -9 $(jobs -p) 2>/dev/null
	$opt_flamegraph && flamegraph_stop
done; done; done

exit 0
