#!/bin/bash
# set -v # echo command, print variables
# set -x # echo command, print values

function incpuset() {
	[ $# -eq 2 ] || return 1
	[ "$2" = "(null)" ] && return 1
	local range low high cpu
	for range in $(echo $2|tr , ' '); do
		 low=$(echo $range|cut -f1 -d-)
		high=$(echo $range|cut -f2 -d-)
		for ((cpu=$low;cpu<=$high;cpu++)); do
			[ $1 -eq $cpu ] && return 0
		done
	done
	return 1
}

# boot: nohz_full=<target cpuset> irqaffinity=<other cpuset> (consider HT)
# could use isolcpus=domain,managed_irq,<target cpuset>, but then threads need to be placed explicitly
# could use isolcpus to acquiesce secondary HTs
[ "$1" = "-c" ] && {
	[ $# -eq 2 ] || {
		echo "usage $0 [-c <cpuset>]"
		exit 1
	}

	[ "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)" = "tsc" ] || {
		echo WARNING: current_clocksource should be tsc
	}

	for range in $(echo $2|tr , ' '); do
		 low=$(echo $range|cut -f1 -d-)
		high=$(echo $range|cut -f2 -d-)
		for ((cpu=$low;cpu<=$high;cpu++)); do
			incpuset $cpu $(cat /sys/devices/system/cpu/nohz_full) || echo "WARNING: core $cpu not in nohz_full set"
		done
	done

	exit 0
}

sudo sh -c "echo 0 > /proc/sys/kernel/yama/ptrace_scope"         # gdb attach
sudo sh -c "echo -1 > /proc/sys/kernel/perf_event_paranoid"      # perf anything
sudo sh -c "echo 0 > /proc/sys/kernel/kptr_restrict"             # perf tracing
sudo sh -c "echo 0 > /proc/sys/kernel/nmi_watchdog"              # perf cache tracing

sudo mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
sudo mount -o remount,mode=755 /sys/kernel/debug
sudo mount -t tracefs tracefs /sys/kernel/debug/tracing 2>/dev/null
sudo mount -o remount,mode=755 /sys/kernel/debug/tracing
sudo chmod -R go+r /sys/kernel/tracing/
sudo find /sys/kernel/tracing/ -type d -exec chmod go+x {} \;

[ -d /sys/devices/system/cpu/intel_pstate ] && {
	sudo sh -c "echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct"
	sudo sh -c "echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct"
	sudo sh -c "echo 1   > /sys/devices/system/cpu/intel_pstate/no_turbo"
} || {
	echo
	echo WARNING: intel_pstate not found
	echo
}

for f in /sys/devices/system/cpu/cpu*/cpufreq; do
	sudo sh -c "echo performance > $f/scaling_governor"
	sudo sh -c "cat $f/cpuinfo_max_freq > $f/scaling_min_freq"
done

# echo -1 | sudo tee /proc/sys/kernel/sched_rt_runtime_us

[ -x ./setup_$HOSTNAME.sh ] && ./setup_$HOSTNAME.sh

exit 0
