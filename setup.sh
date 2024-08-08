#!/bin/bash
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

exit 0
