#!/bin/bash
# set -v # echo command, print variables
# set -x # echo command, print values

SAR="${SAR:-sar}"
PERF="${PERF:-perf}"
SOCAT="${SOCAT:-socat}"
FGDIR="${FGDIR:-FlameGraph}"
BPFTRACE="${BPFTRACE:-bpftrace}"

function ERROR() {
	echo
	echo ERROR: "$*"
	echo
	exit 1
}

function DEBUG() {
#	echo "$*"
	return
}

function show_cases() {
	case_start=$(grep -Fn "$1 case_start" $2|tail -1|cut -f1 -d:)
	case_end=$(grep -Fn "$1 esac_end" $2|tail -1|cut -f1 -d:)
	case_start=$(($case_start+1))
	case_end=$(($case_end-1))
	cases_available=$(sed -n "${case_start},${case_end}p" $0 | sed 's/#.*//' | tr '\n' ' ' | sed 's/;;/\n/g' | sed 's/).*//;s/[[:blank:]]*//' | grep -Fvw \*)
	echo $cases_available
}

function check_port() {
	port=$1
	shift
	timeout 30s pdsh -w $* "while ! $SOCAT /dev/null TCP:localhost:$port 2>/dev/null; do sleep 1; done"
}

function tcptrace_start() {
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh >/dev/null
}

function tcptrace_stop() {
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh | sort | tee tcp-$file.out
}

function bpftrace_start() {
	ssh -f $SERVER "sudo $BPFTRACE -e 'tracepoint:napi:napi_poll { @[args->work] = count(); }'" > poll-$file.out
#	ssh -f $SERVER "sudo $BPFTRACE -e 'tracepoint:napi:napi_debug { @[args->op,args->napi_id,args->cpu,args->data] = count(); }'" > napi-$file.out
}

function bpftrace_stop() {
	ssh $SERVER sudo killall -q bpftrace
}

function bpftrace_kill() {
	ssh $SERVER sudo killall -q -9 bpftrace 2>/dev/null
}

function polltrace_start() {
	ssh $SERVER sudo sh -c "'echo hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
}

function polltrace_stop() {
  ssh $SERVER cat /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/hist|grep -F mc-worker > epoll-$file.out
  ssh $SERVER sudo sh -c "'echo \!hist:key=common_pid.execname,ret > /sys/kernel/debug/tracing/events/syscalls/sys_exit_epoll_wait/trigger'"
}

function sartrace_run() {
	ssh -f $SERVER "sleep $1; taskset -c $observer $SAR -P $allcpuset -u ALL 1 $2" > $SAR-$file.out
}

function flamegraph_start() {
	ssh -f $SERVER "sleep $1; taskset -c $observer $PERF record -C $allcpuset -F 99 -g -o perf.data -- sleep $2 >/dev/null"
}

function flamegraph_stop() {
	# need ssh -t here, otherwise 'perf script' assumes that stdin is a file and won't run
	ssh -t $SERVER "$PERF script >out.perf && $FGDIR/stackcollapse-perf.pl out.perf >out.folded && $FGDIR/flamegraph.pl out.folded >flamegraph.svg"
	scp $SERVER:flamegraph.svg flamegraph-$file.svg && ssh $SERVER "rm -f perf.data out.perf out.folded flamegraph.svg"
}

function perfevent_run() {
	ssh -f $SERVER "sleep $1; taskset -c $observer $PERF stat -C $allcpuset -e $opt_events --no-big-num -- sleep $2 2>&1" > perf-$file.out
}

function irqtrace_start() {
	ssh $SERVER ./irq.sh $IFACE count > /dev/null
}

function irqtrace_stop() {
	ssh $SERVER ./irq.sh $IFACE count | tee irq-$file.out
}

function memcached_stats() {
	ssh $SERVER "(echo stats;sleep 1)|telnet localhost 11211" > stats-$file.out
}
