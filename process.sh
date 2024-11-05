#!/bin/bash
function usage() {
	echo "usage: $(basename $0) [-c|-s] <file> <text> <avg col> [<weight col>]"
	echo "       $(basename $0) [-s] cpq|ipq"
	echo "       $(basename $0)  -q|-r|-t [<sort row>]"
	exit 0
}

[ $# -lt 1 ] && usage

OUTPUT=qps

case $1 in
	-s) SORT="sort -n -k 3"; shift;;
	*)  SORT=cat
esac

case $1 in
	-c) OUTPUT=tc;           shift; [ $# -lt 3 ] && usage;;
	-q) OUTPUT=qtable;       shift;;
	-r) OUTPUT=rtable;       shift;;
	-t) OUTPUT=table;        shift;;
	cpq) OUTPUT=xpq; COUNT=cycles; shift;;
	ipq) OUTPUT=xpq; COUNT=instructions; shift;;
	*)  [ $# -lt 3 ] && usage;;
esac

file=$1
text=$2
shift 2

TC=$(ls *.out|cut -f3 -d-|sort -V|uniq)
QPS=$(ls *.out|cut -f2 -d-|sort -n|uniq)
# move 0 (max) to the end
echo $QPS|grep -q "^0 " && QPS="$(echo $QPS|cut -f2- -d' ') 0"

function getnumber() {
	pos=$1
	case $file in
		sar)	filter="grep -Fv CPU | awk '{print \$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, (100 - \$12)}'";;
		poll)	filter="tr [] ' '";;
		mutilate) [ $pos -eq 5 ] && { filter="cut -f2 -d'(' | cut -f1 -d' '"; pos=1; } || filter=cat;;
		*)		filter=cat;;
	esac
	ls $file-$q-$t-*.out >/dev/null 2>&1 \
	&& grep -F $text $file-$q-$t-*.out|eval "$filter"|$(dirname $0)/avg.sh $pos $2 \
	|| echo X
}

case $OUTPUT in
	table)
		for t in $TC; do
			echo $t
			printf "%6s%8s%8s%8s%8s%8s%8s%8s\n" load qps avglat 95%lat 99%lat cpu cpq ipq
			for q in $QPS; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%6s" $s
				file=mutilate; text=QPS;  getnumber 4  |awk '{printf "%8.0f", $2}'
				file=mutilate; text=read; getnumber 2  |awk '{printf "%8.0f", $6}'
				file=mutilate; text=read; getnumber 9  |awk '{printf "%8.0f", $6}'
				file=mutilate; text=read; getnumber 10 |awk '{printf "%8.0f", $6}'
				file=sar; text=Average;   getnumber 12 |awk '{printf "%8.0f", $2}'
				wrk=$(file=mutilate; text=QPS; getnumber 5|awk '{print $2}')
				file=perf; text=cycles;        getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
				file=perf; text=instructions;  getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
				echo
			done;echo
		done;;
	qtable)
		[ $# -gt 0 ] && SORT="sort -n -k $1" || SORT="cat"
		for q in $QPS; do
			printf "%10s%6s%8s%8s%8s%8s%8s%8s%8s\n" testcase load qps avglat 95%lat 99%lat cpu cpq ipq
			for t in $TC; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%10s%6s" $t $s
				file=mutilate; text=QPS;  getnumber 4  |awk '{printf "%8.0f", $2}'
				file=mutilate; text=read; getnumber 2  |awk '{printf "%8.0f", $6}'
				file=mutilate; text=read; getnumber 9  |awk '{printf "%8.0f", $6}'
				file=mutilate; text=read; getnumber 10 |awk '{printf "%8.0f", $6}'
				file=sar; text=Average;   getnumber 12 |awk '{printf "%8.0f", $2}'
				wrk=$(file=mutilate; text=QPS; getnumber 5|awk '{print $2}')
				file=perf; text=cycles;        getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
				file=perf; text=instructions;  getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
				echo
			done|$SORT;echo
		done;;
	rtable)
		for t in $TC; do
			echo $t
			printf "%6s" load; for q in $QPS; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%8s" $s
			done;echo
			printf "%6s" qps; for q in $QPS; do
				file=mutilate; text=QPS;  getnumber 4  |awk '{printf "%8.0f", $2}'
			done;echo
			printf "%6s" avglat; for q in $QPS; do
				file=mutilate; text=read; getnumber 2  |awk '{printf "%8.0f", $6}'
			done;echo
			printf "%6s" 95%lat; for q in $QPS; do
				file=mutilate; text=read; getnumber 9  |awk '{printf "%8.0f", $6}'
			done;echo
			printf "%6s" 99%lat; for q in $QPS; do
				file=mutilate; text=read; getnumber 10 |awk '{printf "%8.0f", $6}'
			done;echo
			printf "%6s" cpu; for q in $QPS; do
				file=sar; text=Average;   getnumber 12 |awk '{printf "%8.0f", $2}'
			done;echo
			printf "%6s" cpq; for q in $QPS; do
				wrk=$(file=mutilate; text=QPS; getnumber 5|awk '{print $2}')
				file=perf; text=cycles;        getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
			done;echo
			printf "%6s" ipq; for q in $QPS; do
				wrk=$(file=mutilate; text=QPS; getnumber 5|awk '{print $2}')
				file=perf; text=instructions;  getnumber 2|awk -v wrk=$wrk '{printf "%8.0f", $2 / wrk}'
			done;echo
			echo
		done;;
	qps)
		for q in $QPS; do for t in $TC; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%5s %12s" $s $t; getnumber $*|awk '{printf "%18.3f %18.3f %6.3f %18.3f %6.3f\n", $2, $4, $5, $6, $7}'
		done|$SORT; echo; done;;
	tc)
		for t in $TC; do for q in $QPS; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%12s %5s" $t $s; getnumber $*|awk '{printf "%18.3f %18.3f %6.3f %18.3f %6.3f\n", $2, $4, $5, $6, $7}'
		done; echo; done;;
	xpq)
		for q in $QPS; do for t in $TC; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%5s %12s" $s $t
			for r in $(ls mutilate-$q-$t-*.out|cut -f4 -d-|cut -f1 -d.); do
				wrk=$(grep -F QPS mutilate-$q-$t-$r.out|cut -f2 -d'(' | cut -f1 -d' ')
				cnt=$(grep -F $COUNT perf-$q-$t-$r.out|awk '{print $1}')
				echo $cnt $wrk | awk '{printf "%18.3f\n", $1 / $2}'
			done | avg.sh 1 | awk '{printf "%18.3f %18.3f %6.3f %18.3f %6.3f\n", $2, $4, $5, $6, $7}'
		done | $SORT; echo; done;;
	*)   echo internal error; exit 1;;
esac

exit 0

# sample invocations, by load, then TC, -s sorted by result
process.sh -s mutilate QPS 4        # throughput
process.sh -s mutilate read 2       # average latency
process.sh -s mutilate read 3       # minimum latency
process.sh -s mutilate read 9       # 95th percentile latency
process.sh -s mutilate read 10      # 99th percentile latency
process.sh -s sar Average 9         # softirq time
process.sh -s sar Average 12        # cpu utilization
process.sh -s irq total 2           # total irqs
process.sh -s irq total 3           # total pkts received
process.sh -s perf instructions 5   # average IPC
process.sh -s epoll mc-worker 7 10  # average epoll return count
process.sh -s poll @ 2 4            # average napi poll count

process.sh -c mutilate QPS 4        # throughput, by TC, then load

process.sh -t   # table by tc:  load in y, result in x
process.sh -r   # table by tc:  load in x, result in y
process.sh -q 6 # table by qps: tc in x, result in y, sorted by 99%lat

process.sh sar Average 12|sort -n -k 5 # maximum COV

# sort all runs by COV of rx packet distribution across queues
for f in irq-*; do
	tail +2 $f | grep -Fv async | grep -Fv total | avg.sh 4 | awk '{printf "%18.3f %18.3f %6.3f ", $2, $4, $5}'
	echo "$f "
done|sort -n -k 3

# sort by COV to detect outliers in data set
process.sh mutilate QPS 4|sort -g -k5
process.sh mutilate read 10|sort -g -k5

# test for empty multilate files
for f in mutilate-*; do [ -s $f ] || echo $f; done

# remove empty files
for f in mutilate-*; do [ -s $f ] || rm *-$(echo $f|cut -f2- -d-); done

# test for files with non-zero Misses
grep -FH Misses mutilate-*.out|fgrep -Fv "= 0"|cut -f1 -d:

# remove tests with Misses
for f in $(grep -FH Misses mutilate-*.out|fgrep -Fv "= 0"|cut -f1 -d:); do rm *-$(echo $f|cut -f2- -d-); done

# show CPQ (or IPQ with 'instructions' instead of 'cycles')
for f in mutilate-*; do
	q=$(grep -F QPS $f|awk '{print $5}'|cut -f2 -d\()
	c=$(grep -F cycles perf-$(echo $f|cut -f2- -d-)|awk '{print $1}')
	echo -n "$f "; echo "$c $q"|awk '{print $1 / $2}'
done
