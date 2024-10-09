#!/bin/bash
# set -v # echo command, print variables
# set -x # echo command, print values

function error() {
	echo $*
	exit 1
}

function DEBUG() {
#	echo $*
	return
}

function usage() {
	echo usage:
	echo "$(basename $0) boot"
	echo "$(basename $0) turboget"
	echo "$(basename $0) turboset [min] [max] [on]"
	exit 0
}

[ $# -lt 1 ] && usage;

case $1 in
	boot)
		sudo -s sh -c "echo 0 > /proc/sys/kernel/yama/ptrace_scope"         # gdb attach
		sudo -s sh -c "echo -1 > /proc/sys/kernel/perf_event_paranoid"      # perf anything
		sudo -s sh -c "echo 0 > /proc/sys/kernel/kptr_restrict"             # perf tracing
		sudo -s sh -c "echo 0 > /proc/sys/kernel/nmi_watchdog"              # perf cache tracing
		sudo mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
		sudo mount -o remount,mode=755 /sys/kernel/debug
		sudo mount -t tracefs tracefs /sys/kernel/debug/tracing 2>/dev/null
		sudo mount -o remount,mode=755 /sys/kernel/debug/tracing
		sudo find /sys/kernel/tracing/ -type d -exec chmod go+x {} \;
		sudo chmod -R go+r /sys/kernel/tracing/
		[ -x ./setup_$HOSTNAME.sh ] && ./setup_$HOSTNAME.sh
		;;
	turboget)
		[ -d /sys/devices/system/cpu/intel_pstate ] && {
			cat /sys/devices/system/cpu/intel_pstate/min_perf_pct
			cat /sys/devices/system/cpu/intel_pstate/max_perf_pct
			cat /sys/devices/system/cpu/intel_pstate/no_turbo
		};;
	turboset)
		[ $# -lt 4 ] && usage;
		[ -d /sys/devices/system/cpu/intel_pstate ] && {
			sudo sh -c "echo $2 > /sys/devices/system/cpu/intel_pstate/min_perf_pct"
			sudo sh -c "echo $3 > /sys/devices/system/cpu/intel_pstate/max_perf_pct"
			sudo sh -c "echo $4 > /sys/devices/system/cpu/intel_pstate/no_turbo"
		};;
	*) usage;;
esac

exit 0
