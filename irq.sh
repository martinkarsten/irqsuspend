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
	echo "$(basename $0) <interface> count [raw]"
	echo "$(basename $0) <interface> irqmap"
	echo "$(basename $0) <interface> setq <count>"
	echo "$(basename $0) <interface> setirq1 <cpuset> <irq idx> <irq cnt>"
	echo "$(basename $0) <interface> setirqN <cpuset> <irq idx> <irq cnt>"
	echo "$(basename $0) <interface> setcoalesce <adaptive-rx> <adaptive-tx> <rx-usecs> <rx-frames> <rx-usecs-irq> <rx-frames-irq> <tx-usecs> <tx-frames> <tx-usecs-irq> <tx-frames-irq> <cqe-mode-rx> <cqe-mode-tx?"
	echo "$(basename $0) <interface> setpoll <gro timeout> <defer irqs> <suspend timeout>"
	echo "$(basename $0) <interface> show"
	exit 0
}

[ $# -gt 1 ] || usage;

dev=$1; shift
[ -d /sys/class/net/$dev ] || error device $dev not found

# obtain index list of irqs associated with device
irqlist=($(ls /sys/class/net/$dev/device/msi_irqs|sort -n))
irqtotal=${#irqlist[@]}
DEBUG IRQs: $irqtotal - ${irqlist[@]}

# obtain number of relevant interrupts
rxtotal=$(ethtool -l $dev|grep -F RX:      |head -1|awk '{print $2}'); [ "$rxtotal" = "n/a" ] && rxtotal=0
txtotal=$(ethtool -l $dev|grep -F TX:      |head -1|awk '{print $2}'); [ "$txtotal" = "n/a" ] && txtotal=0
cbtotal=$(ethtool -l $dev|grep -F Combined:|head -1|awk '{print $2}'); [ "$cbtotal" = "n/a" ] && cbtotal=0
qcnttotal=$(($rxtotal + $cbtotal))
rxcurr=$(ethtool -l $dev|grep -F RX:      |tail -1|awk '{print $2}'); [ "$rxcurr" = "n/a" ] && rxcurr=0
txcurr=$(ethtool -l $dev|grep -F TX:      |tail -1|awk '{print $2}'); [ "$txcurr" = "n/a" ] && txcurr=0
cbcurr=$(ethtool -l $dev|grep -F Combined:|tail -1|awk '{print $2}'); [ "$cbcurr" = "n/a" ] && cbcurr=0
qcntcurr=$(($rxcurr + $cbcurr))
DEBUG QUEUEs: $rxtotal $txtotal $cbtotal $qcnttotal $rxcurr $txcurr $cbcurr $qcntcurr
[ $qcnttotal -le $irqtotal ] || error "qcnttotal $qcnttotal > irqtotal $irqtotal"
[ $qcntcurr -le $qcnttotal ] || error "qcntcurr $qcntcurr > qcnttotal $qcnttotal"

if [[ $NDCLI ]]; then
	ifx=$(ip l show $dev|head -1|cut -f1 -d:)
	napiraw=($($NDCLI --dump queue-get --json="{\"ifindex\": $ifx}"|jq '.[] | .id,."napi-id"'))
	for ((i=0;i<${#napiraw[@]};i+=2)); do
		napimap[${napiraw[i]}]=${napiraw[i+1]}
	done
	DEBUG ${napimap[@]}
fi

if [ "$1" = "irqmap" ]; then
	shift
	if [[ $NDCLI ]]; then
		echo ${irqlist[@]}
		irqsraw=($($NDCLI --dump napi-get --json="{\"ifindex\": $ifx}"|jq '.[] | .id,.irq'))
		for ((i=0;i<${#irqsraw[@]};i+=2)); do
			tempirqmap[${irqsraw[i]}]=${irqsraw[i+1]}
		done
		for ((q=0;q<$qcnttotal;q+=1)); do
			irqmap[$q]=${tempirqmap[napimap[q]]}
		done
		echo ${irqmap[@]}
		unset irqmap
	else
		error "cannot determine irq map, if netdev-genl cli is not provided"
	fi
fi

driver=$(ethtool -i $dev | grep -F driver | awk '{print $2}')
DEBUG $driver

# use hard-coded irqmap
case $driver in
mlx4_en|mlx5_core)
	pci_id=$(basename $(readlink /sys/class/net/$dev/device))
	part=$(sudo lspci -vv -s $pci_id | fgrep Part | awk '{print $4}')
	DEBUG $part
	case $part in
	649283-B21|661687-001) # mlx4_en: tilly machines
		irqmap=(33 34 35 36 37 38 39 40 49 50 51 52 53 54 55 56 41 42 43 44 45 56 47 48 57 58 59 60 61 62 63 64);;
	MCX311A-XCAT)          # mlx4_en: red01, red01vm (PCI passthrough)
		case $HOSTNAME in
		red01vm)
			irqmap=( 1  2  3  4  5  6);;
		*)
			irqmap=( 7  8  9 10 11 12 19 20 21 22 23 24  1  2  3  4  5  6 13 14 15 16 17 18);;
		esac;;
	MCX4121A-ACAT)         # mlx5_core: tilly01
		irqmap=( 1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32);;
	MCX515A-CCAT)          # mlx5_core: intrepid node10
		irqmap=( 1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20);;
	MCX516A-CDAT)          # mlx5_core: cache-sql13432
		irqmap=( 1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63);;
	*) error unsupported part $part for $driver;;
	esac;;
*)
	case $HOSTNAME in
	*)
		mac=$(echo $(ip -br l show $dev) | awk '{print $3}')
		case $mac in
		*)
			error unsupported driver $driver and mac $mac;;
		esac;;
	esac;;
esac

DEBUG ${irqmap[@]}

# sanitychecking
[ $qcnttotal -eq ${#irqmap[@]} ] || error inconsistency between qcnttotal $qcnttotal and size of irqmap ${#irqmap[@]}

# process command-line arguments
raw=false
count=false
while [ $# -gt 0 ]; do
	case $1 in
	count)
		count=true; shift
		[ "$1" = "raw" ] && { raw=true; shift; };;
	setq)
		[ $# -lt 2 ] && usage
		[ "$2" = "max" ] && cnt=$qcnttotal || cnt=$2
		case $driver in
		mlx5_core)
			sudo ethtool -L $dev combined $cnt;;
		mlx4_en)
			sudo ethtool -L $dev rx $cnt;;
		*)
			error channel settings: unsupported $driver;;
		esac
		shift 2;;
	getq)
		echo $qcntcurr
		shift 1;;
	setirq1)
		[ $# -lt 4 ] && usage
		[ $4 -gt 0 ] && max=$(($3 + $4)) || max=$irqtotal
		idx=$3
		while [ $idx -lt $max ]; do
			for range in $(echo $2|tr , ' '); do
				low=$(echo $range|cut -f1 -d-)
			  high=$(echo $range|cut -f2 -d-)
				for ((cpu=$low;cpu<=$high;cpu++)); do
					# route each irq to a dedicated core (linear assignment)
					sudo sh -c "echo $cpu > /proc/irq/${irqlist[${irqmap[idx]}]}/smp_affinity_list"
					# clear RPS, set XPS to dedicated core
					sudo sh -c "echo 0 > /sys/class/net/$dev/queues/rx-$idx/rps_cpus"
					sudo sh -c "echo 0 > /sys/class/net/$dev/queues/rx-$idx/rps_flow_cnt"
					sudo sh -c "echo 0 > /sys/class/net/$dev/queues/tx-$idx/xps_rxqs"
					str=$(printf '%X' $((2 ** $(($cpu % 32)))))
					for ((tmp=$cpu;tmp>=32;tmp-=32)); do str+=",00000000"; done
					sudo sh -c "echo $str > /sys/class/net/$dev/queues/tx-$idx/xps_cpus"
					((idx+=1))
					[ $idx -ge $max ] && break
				done
				[ $idx -ge $max ] && break
			done
		done
		shift 4;;
	setirqN)
		[ $# -lt 4 ] && usage
		[ $4 -gt 0 ] && max=$(($3 + $4)) || max=$irqtotal
		for ((idx=$3;idx<$max;idx++)); do
			[ -r /proc/irq/${irqlist[idx]}/smp_affinity_list ] || continue;
		  sudo sh -c "echo $2 > /proc/irq/${irqlist[idx]}/smp_affinity_list"
		done
		shift 4;;
	setcoalesce)
		[ $# -lt 13 ] && usage; shift
		COALESCING=""
		[ "$1" = "na" ] || COALESCING+=" adaptive-rx $1"; shift
		[ "$1" = "na" ] || COALESCING+=" adaptive-tx $1"; shift
		[ "$1" = "na" ] || COALESCING+=" rx-usecs $1"; shift
		[ "$1" = "na" ] || COALESCING+=" rx-frames $1"; shift
		[ "$1" = "na" ] || COALESCING+=" rx-usecs-irq $1"; shift
		[ "$1" = "na" ] || COALESCING+=" rx-frames-irq $1"; shift
		[ "$1" = "na" ] || COALESCING+=" tx-usecs $1"; shift
		[ "$1" = "na" ] || COALESCING+=" tx-frames $1"; shift
		[ "$1" = "na" ] || COALESCING+=" tx-usecs-irq $1"; shift
		[ "$1" = "na" ] || COALESCING+=" tx-frames-irq $1"; shift
		[ "$1" = "na" ] || COALESCING+=" cqe-mode-rx $1"; shift
		[ "$1" = "na" ] || COALESCING+=" cqe-mode-tx $1"; shift
		sudo ethtool -C $dev $COALESCING
		;;
	setpoll)
		[ $# -lt 4 ] && usage
		if [[ $NDCLI ]]; then
			for ((q=0;q<$qcntcurr;q++)); do
				nid=${napimap[q]}
				sudo $NDCLI --do napi-set --json="{\"id\": $nid, \"gro-flush-timeout\": $2, \"defer-hard-irqs\": $3}" > /dev/null
				sudo $NDCLI --do napi-set --json="{\"id\": $nid, \"irq-suspend-timeout\": $4}" >/dev/null 2>&1 || echo "irq-suspend-timeout not available"
			done
		else
			sudo sh -c "echo $2 > /sys/class/net/$dev/gro_flush_timeout"
			sudo sh -c "echo $3 > /sys/class/net/$dev/napi_defer_hard_irqs"
#			[ -e /sys/class/net/$dev/irq_suspend_timeout ] && \
#				sudo sh -c "echo $4 > /sys/class/net/$dev/irq_suspend_timeout" || \
#				echo "irq_suspend_timeout not available"
		fi
		shift 4;;
	show)
		# TODO: also show IRQ routing...
		ethtool -c $dev|while read line; do
			echo $line|grep -E "on|off" || echo $line|grep -Fv "n/a"
		done|grep -v $dev|grep -Ev "^$"
		ethtool -g $dev|grep -Fv "n/a"|grep -v $dev|grep -Ev "^$"
		ethtool -l $dev|grep -Fv "n/a"|grep -v $dev|grep -Ev "^$"
		echo -n "gro_flush_timeout: "; cat /sys/class/net/$dev/gro_flush_timeout
		echo -n "napi_defer_hard_irqs: "; cat /sys/class/net/$dev/napi_defer_hard_irqs
#		echo -n "irq_suspend_timeout: "
#		[ -e /sys/class/net/$dev/irq_suspend_timeout ] && \
#			cat /sys/class/net/$dev/irq_suspend_timeout || \
#			echo not available
		[[ $NDCLI ]] && $NDCLI --dump napi-get --json="{\"ifindex\": $ifx}"|jq .
		shift;;
	*) error unknown operation $1;;
	esac
done

$count || exit 0

prevfile=$HOME/.irq.sh.previous.$HOSTNAME.$dev

# setup current counters
for ((idx=0;idx<$irqtotal;idx++)); do
	rxpktcnt[idx]=0
	txpktcnt[idx]=0
done

# obtain current packet counters from ethtool -S
idx=0
for x in $(ethtool -S $dev|grep -E "(rx[0-9][0-9]*_packets:|rx_queue_[0-9][0-9]*_packets:)"|cut -f2 -d:); do
	[ ${irqmap[idx]} ] && rxpktcnt[irqmap[idx]]=$((${rxpktcnt[irqmap[idx]]} + $x))
	idx=$(($idx + 1))
done
idx=0
for x in $(ethtool -S $dev|grep -E "(tx[0-9][0-9]*_packets:|tx_queue_[0-9][0-9]*_packets:)"|cut -f2 -d:); do
	[ ${irqmap[idx]} ] && txpktcnt[irqmap[idx]]=$((${txpktcnt[irqmap[idx]]} + $x))
	idx=$(($idx + 1))
done

# obtain current packet drop counters from ethtool -S
s=$(ethtool -S $dev|grep -E "(tx_dropped:|tx_queue_dropped:)")
[ -z "$s" ] && txdrops=0 || txdrops=$(echo $s|awk '{print $2}')

# mlx5 does not report rx_dropped, but it does report rx_buff_alloc_err
s=$(ethtool -S $dev|grep -E "(rx_dropped:|rx_buff_alloc_err:)")
[ -z "$s" ] && rxdrops=0 || rxdrops=$(echo $s|awk '{print $2}')

# obtain current IRQ counters from /proc
irqline=($(grep -F intr /proc/stat|cut -f3- -d' '))
for ((idx=0;idx<$irqtotal;idx++)); do
	irqcnt[idx]=${irqline[irqlist[idx]]}
done

DEBUG rx curr: ${rxpktcnt[@]}
DEBUG tx curr: ${txpktcnt[@]}
DEBUG irq curr: ${irqcnt[@]}

# read previous counters, if needed
$raw || {
	touch $prevfile

	idx=0
	for x in $(grep -F rxpkts: $prevfile|cut -f2 -d:); do
		rxpktcntprev[idx]=$x
		idx=$(($idx + 1))
	done
	for ((;idx<$irqtotal;idx++)); do rxpktcntprev[idx]=0; done

	idx=0
	for x in $(grep -F txpkts: $prevfile|cut -f2 -d:); do
		txpktcntprev[idx]=$x
		idx=$(($idx + 1))
	done
	for ((;idx<$irqtotal;idx++)); do txpktcntprev[idx]=0; done

	s=$(grep -F txdrops: $prevfile)
	[ -z "$s" ] && txdropsprev=0 || txdropsprev=$(echo $s|cut -f2 -d:)
	s=$(grep -F rxdrops: $prevfile)
	[ -z "$s" ] && rxdropsprev=0 || rxdropsprev=$(echo $s|cut -f2 -d:)

	idx=0
	for x in $(grep -F irqs: $prevfile|cut -f2 -d:); do
		irqcntprev[idx]=$x
		idx=$(($idx + 1))
	done
	for ((;idx<$irqtotal;idx++)); do irqcntprev[idx]=0; done

	DEBUG rx prev: ${rxpktcntprev[@]}
	DEBUG tx prev: ${txpktcntprev[@]}
	DEBUG irq prev: ${irqcntprev[@]}

	# write new counters
	echo rxpkts: ${rxpktcnt[@]} > $prevfile
	echo txpkts: ${txpktcnt[@]} >> $prevfile
	echo "rxdrops: $rxdrops" >> $prevfile
	echo "txdrops: $txdrops" >> $prevfile
	echo irqs: ${irqcnt[@]} >> $prevfile

	# compute increments
	for ((idx=0;idx<$irqtotal;idx++)); do
		rxpktcnt[idx]=$((${rxpktcnt[idx]} - ${rxpktcntprev[idx]}))
		txpktcnt[idx]=$((${txpktcnt[idx]} - ${txpktcntprev[idx]}))
		  irqcnt[idx]=$((${irqcnt[idx]} - ${irqcntprev[idx]}))
	done
	txdrops=$(($txdrops - $txdropsprev))
	rxdrops=$(($rxdrops - $rxdropsprev))

	DEBUG rx now: ${rxpktcnt[@]}
	DEBUG tx now: ${txpktcnt[@]}
	DEBUG irq now: ${irqcnt[@]}
}

# print output
rxpktsum=0
txpktsum=0
irqsum=0
printf "idx irq %12s %12s %12s %12s name\n" fired rxpkts txpkts cpus
for ((idx=0;idx<$irqtotal;idx++)); do
	irqnum=${irqlist[idx]}
	[ -r /proc/irq/$irqnum/smp_affinity_list ] || continue;
	irqs=${irqcnt[idx]}
	rxpkts=${rxpktcnt[idx]}
	txpkts=${txpktcnt[idx]}
	cpus=$(cat /proc/irq/$irqnum/smp_affinity_list)
	name=$(cat /sys/kernel/irq/$irqnum/actions|cut -f1 -d@)
	if $raw || [ $(($irqs + $rxpkts + $txpkts)) -gt 0 ]; then
		printf "%3d %3d %12d %12d %12d %12s %s\n" $idx $irqnum $irqs $rxpkts $txpkts $cpus $name
	fi
	rxpktsum=$(expr $rxpktsum + $rxpkts)
	txpktsum=$(expr $txpktsum + $txpkts)
	irqsum=$(expr $irqsum + $irqs)
done
printf "total   %12d %12d %12d\n" $irqsum $rxpktsum $txpktsum
[ $(($rxdrops + $txdrops)) -gt 0 ] &&
printf "drops   %12s %12d %12d\n" "" $rxdrops $txdrops

exit 0
