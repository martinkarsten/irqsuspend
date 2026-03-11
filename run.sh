#!/bin/bash

source $(dirname $0)/util.sh

function usage() {
  echo "$(basename $0) [cp] [options] <server> [<# runs> | clean]"
  echo "Options:"
  echo "-b                 build kernel first"
  echo "-c num             server cpus"
  echo "-d num             mutilate pipeline depth"
  echo "-h                 hyperthread mode"
  echo "-n num             connections per mutilate thread"
  echo "-m num             number of mutilate threads per client"
  echo "-p ev1,ev2,...     perf event set (or flame, mem)"
  echo "-q qps1,qps2,...   load rates"
  echo "-s                 set skip flag (-S) in mutilate"
  echo "-t test1,test2,... test cases"
  echo "-T duration        duration of each in seconds"
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
arg_depth=1
opt_ht=false
arg_conns=24
unset arg_mutcores
opt_events="cycles,instructions,mem_uops_retired.all_loads,mem_uops_retired.all_stores"
unset arg_qps
unset arg_skip
TESTCASES=$(show_cases testcases $0)
arg_time=30
while getopts "bc:d:hm:n:p:q:st:T:" option; do
case $option in
	b) opt_build=true;;
	c) arg_cores=${OPTARG};;
	d) arg_depth=${OPTARG};;
	h) opt_ht=true;;
	n) arg_conns=${OPTARG};;
	m) arg_mutcores=${OPTARG};;
	p) opt_events=${OPTARG};;
	q) arg_qps=$(echo ${OPTARG}|tr , ' ');;
	s) arg_skip=" -S";;
	t) TESTCASES=$(echo ${OPTARG}|tr , ' ');;
	T) arg_time=${OPTARG};;
	*) usage;;
esac; done
shift $(($OPTIND - 1))

# set a default
COALESCEd="na na na na na na na na na na na na"
COALESCEx="na na na na na na na na na na na na"

# client & server settings based on server name
[ $# -gt 0 ] || usage
case $1 in
red01|red01vm|small|tilly01|tilly01vm|tilly02|node10|husky10)
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

[[ $arg_mutcores ]] && MUTCORES=$arg_mutcores

[ $# -gt 0 ] && { RUNS=$1; shift; } || RUNS=1

[ $# -gt 0 ] && usage

# print summary
echo "server: $SERVER; driver: $DRIVER; clients: $CLIENTS"
echo "tests: $TESTCASES"
echo "runs: $RUNS; rates: $QPS"
echo "cores: $CORES; ht: $opt_ht; conns: $arg_conns; mutcores: $MUTCORES"

[ -z "$CLIENTS" ] && allclients="$DRIVER" || allclients="$DRIVER,$CLIENTS"

[ "$RUNS" = "show" ] && exit 0

cleanup() {
	pdsh -w $allclients killall -q -9 mutilate 2>/dev/null
	ssh $SERVER killall -q -9 memcached 2>/dev/null
	$TRACING && bpftrace_kill
}

check_last_file() {
	[ $file ] || return
	[ -s mutilate-$file.out ] || rm -f *-$file.out
}

# basic setup
[ "$CLIENTS" ] && AGENTS=$(for m in $(echo $CLIENTS|tr , ' '); do echo -n " -a $m";done)
MUTARGS="-s $SERVER_IP -K fb_key -V fb_value -i fb_ia -r $MEMKEYS"
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
files=$(echo $dir/{irq,setup,util}.sh)
[ -f $dir/servercfg/setup_$SERVER.sh ] && files+=" $dir/servercfg/setup_$SERVER.sh"
scp $files $SERVER: >/dev/null 2>&1 &
for h in $(echo $allclients|tr , ' '); do scp $dir/tcp.sh $h: >/dev/null 2>&1 & done
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
	conns=$arg_conns; cpus=$CORES
	case "$tc" in # testcases case_start
		base)       CL=d; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		base0c)     CL=x; HTSPLIT=true;  POLLVAR="       0   0        0"; MEMVAR="";;
		defer20)    CL=d; HTSPLIT=true;  POLLVAR="   20000 100        0"; MEMVAR="";;
		defer200)   CL=d; HTSPLIT=true;  POLLVAR="  200000 100        0"; MEMVAR="";;
		napibusy)   CL=d; HTSPLIT=false; POLLVAR="  200000 100        0"; MEMVAR="_MP_Usecs=64   _MP_Budget=64 _MP_Prefer=1";;
		fullbusy)   CL=d; HTSPLIT=false; POLLVAR=" 5000000 100        0"; MEMVAR="_MP_Usecs=1000 _MP_Budget=64 _MP_Prefer=1"; MEMSPEC+=" -y";;
#		suspend1)   CL=d; HTSPLIT=false; POLLVAR="    1000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend2)   CL=d; HTSPLIT=false; POLLVAR="    1000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend5)   CL=d; HTSPLIT=false; POLLVAR="    5000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend10)  CL=d; HTSPLIT=false; POLLVAR="   10000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend20)  CL=d; HTSPLIT=false; POLLVAR="   20000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend50)  CL=d; HTSPLIT=false; POLLVAR="   50000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend100) CL=d; HTSPLIT=false; POLLVAR="  100000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
		suspend200) CL=d; HTSPLIT=false; POLLVAR="  200000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
#		suspend500) CL=d; HTSPLIT=false; POLLVAR="  200000 100 20000000"; MEMVAR="_MP_Usecs=0    _MP_Budget=64 _MP_Prefer=1";;
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
	MEMSPEC="-t $cpus -N $cpus -b 32768 -c 32768 -m 10240 -o hashpower=24,no_lru_maintainer,no_lru_crawler"
	MUTSPEC="-c $conns -q $qps -d $arg_depth -u 0.03 $arg_skip"
	eval COALESCING=\$COALESCE$CL
	ssh $SERVER NDCLI=\"$NDCLI\" ./irq.sh -p $IFACE setq $irqs setirqN $OTHER 0 0 setirq1 $irqcpuset 0 $irqs setcoalesce $COALESCING setpoll $POLLVAR show > setup-$file.out
	printf "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC\n\n" > memcached-$file.out
	printf "$MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t $arg_time\n\n" >> memcached-$file.out
	printf "SERVER "; ssh -f $SERVER "$MEMVAR taskset -c $runcpuset $MEMCACHED $MEMSPEC"
	sleep 1
	check_port 11211 $SERVER || echo "SERVER FAILED" | tee -a memcached-$file.out
	[ "$CLIENTS" ] && {
		printf "AGENTS "
		pdsh -w $CLIENTS "ulimit -n 32768 && $MUTILATE -A" 2>/dev/null &
		sleep 1
		check_port 5556 $CLIENTS || echo "AGENTS FAILED" | tee -a memcached-$file.out
	}
	time3=$(expr $arg_time / 3)
	to3=$(expr $time3 \* 3 / 2)s
	printf "LOAD "; timeout $to3 ssh $DRIVER "ulimit -n 32768 && $MUTILATE $MUTARGS --loadonly" || echo "LOAD FAILED" >> memcached-$file.out
	printf "WARM "; timeout $to3 ssh $DRIVER "ulimit -n 32768 && $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t $time3" >/dev/null 2>&1 || echo "WARMUP FAILED" >> memcached-$file.out
	$TRACING && case $opt_events in
		mem)   perfmem_start $time3 $time3;;
		flame) flamegraph_start $time3 $time3;;
		*)     perfevent_run $time3 $time3;;
	esac
	tcpcount_start
	$TRACING && sartrace_run $time3 $time3
	$TRACING && bpftrace_start
	$TRACING && polltrace_start
	irqcount_start
	to=$(expr $arg_time \* 3 / 2)s
	printf "RUN\n"; timeout $to ssh $DRIVER "ulimit -n 32768 && $MUTILATE $MUTARGS $MUTSPEC $AGENTS --noload -t $arg_time" | tee mutilate-$file.out # experiment
	irqcount_stop
	$TRACING && polltrace_stop
	$TRACING && bpftrace_stop
	$TRACING && memcached_stats
	tcpcount_stop
	pdsh -w $allclients killall -q mutilate
	ssh $SERVER killall -q memcached
	kill -9 $(jobs -p) 2>/dev/null
	ssh $SERVER killall -q -9 memcached
	$TRACING && case $opt_events in
		mem)   perfmem_stop;;
		flame) flamegraph_stop;;
	esac
done; done; done

exit 0
