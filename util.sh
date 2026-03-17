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

# https://stackoverflow.com/a/76512982
function decolor() {
	sed -i -E "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})*)?[m,K,H,f,J]//gm" $1
	sed -i -E "s/\x1B\([A-Z]{1}(\x1B\[[m,K,H,f,J])?//gm" $1
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

function perf_start() {
	ssh -f $SERVER "sleep $3; taskset -c $1 $PERF stat -C $allcpuset -e $2 --no-big-num -- sleep $4 2>&1; \
	          [ $5 -gt 0 ] && taskset -c $1 $PERF mem record -C $allcpuset -F max -o perf.mem.data --ldlat 0 -- sleep $5 2>/dev/null; \
	          [ $6 -gt 0 ] && taskset -c $1 $PERF record  -g -C $allcpuset -F max -o perf.data -- sleep $6 2>/dev/null" > perf-$file.out
}

function perf_stop() {
	[ $1 -gt 0 ] && {
		ssh -t $SERVER "$PERF mem report --sort=mem --stdio -i perf.mem.data" > perfmem-$file.out && decolor perfmem-$file.out
		ssh $SERVER "rm -f perf.mem.data"
	}
	[ $2 -gt 0 ] && {
		ssh -t $SERVER "$PERF script >out.perf && $FGDIR/stackcollapse-perf.pl out.perf >out.folded && $FGDIR/flamegraph.pl out.folded >flamegraph.svg"
		scp $SERVER:flamegraph.svg flamegraph-$file.svg
		ssh $SERVER "rm -f perf.data out.perf out.folded flamegraph.svg"
	}
}

function sartrace_run() {
	ssh -f $SERVER "sleep $2; taskset -c $1 $SAR -P $allcpuset -u ALL 1 $3" > $SAR-$file.out
}

function tcpcount_start() {
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh >/dev/null
}

function tcpcount_stop() {
	pdsh -w $DRIVER,$CLIENTS ./tcp.sh | sort > tcp-$file.out
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

function irqcount_start() {
	ssh $SERVER ./irq.sh $IFACE count > /dev/null
}

function irqcount_stop() {
	ssh $SERVER ./irq.sh $IFACE count > irq-$file.out
}

function memcached_stats() {
	ssh $SERVER "(echo stats;sleep 1)|telnet localhost 11211" > stats-$file.out
}
