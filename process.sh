#!/bin/bash

function usage() {
	echo "usage: $(basename $0) [-c|-s] <file> <text> <avg col> [<weight col>]"
	echo "       $(basename $0) [-s] cpq|ipq"
	echo "       $(basename $0) [-R] -q|-r|-t [<sort row>]"
	exit 0
}

[ $# -lt 1 ] && usage

declare -rA perf_labels=(["cycles"]="cpq"  ["instructions"]="ipq"
 ["mem_uops_retired.all_loads"]="ldpq"
 ["mem_uops_retired.all_stores"]="stpq")

RAW=false
SORT=cat
OUTPUT=qps
PERCENT=false

[ "$1" = "-R" ] && { RAW=true; shift; }
[ "$1" = "-s" ] && { SORT="sort -n -k 3"; shift; }
[ "$1" = "-p" ] && { PERCENT=true; shift; }

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

ls perf-*.out >/dev/null 2>&1 && pcounters=$(cat perf-*.out|sed '/^$/d'|grep -Fv elapsed|grep -Fv Performance|awk '{print $2}'|sort|uniq) || unset pcounters
[[ $pcounters == *"cycles"* ]] && [[ $pcounters == *"instructions"* ]] && perf_ipc=true || perf_ipc=false

function getnumber() {
	pos=$1
	case $file in
		sar)	filter="grep -Fv CPU | awk '{print \$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, (100 - \$12)}'";;
		poll)	filter="tr [] ' '";;
		mutilate) [ $pos -eq 5 ] && { filter="cut -f2 -d'(' | cut -f1 -d' '"; pos=1; } || filter=cat;;
		*)		filter=cat;;
	esac
	ls $file-$q-$t-*.out >/dev/null 2>&1 \
	&& grep -Fh $text $file-$q-$t-*.out|eval "$filter"|$(dirname $0)/avg.sh $pos $2 \
	|| echo X X
}

function print_qps    { file=mutilate; text=QPS;     getnumber  4  |awk '{printf "%8.0f", $2}'; }
function print_avglat { file=mutilate; text=read;    getnumber  2  |awk '{printf "%8.0f", $6}'; }
function print_95lat  { file=mutilate; text=read;    getnumber  9  |awk '{printf "%8.0f", $6}'; }
function print_99lat  { file=mutilate; text=read;    getnumber 10  |awk '{printf "%8.0f", $6}'; }
function print_cpu    { file=sar;      text=Average; getnumber 12  |awk '{printf "%8.0f", $2}'; }

function print_ppi {
	irqs=$(file=irq; text=total; getnumber 2|awk '{print $2}')
	[ "$irqs" = "X" ] && printf "%8s" X || {
		file=irq; text=total; getnumber 3|awk -v irqs=$irqs '{printf "%8.0f", $2 / irqs}'
	}
}

function print_headers {
	printf "%8s%8s%8s%8s%8s%8s" qps avglat 95%lat 99%lat cpu ppi
	[ -z "$pcounters" ] || for c in $pcounters; do
		printf "%8s" ${perf_labels["$c"]}
		$perf_ipc && [[ $c == "instructions" ]] && printf "%8s" ipc
	done
	echo
}

function print_perf_perq {
	wrk=$(file=mutilate; text=QPS; getnumber 4|awk '{print $2}')
	[ -z "$pcounters" ] || for c in $pcounters; do
		val=X
		ls perf-$q-$t-*.out >/dev/null 2>&1 && val=$(for f in perf-$q-$t-*.out; do
			tim=$(grep -F elapsed $f|awk '{print $1}')
			grep -F $c $f|awk -v tim=$tim -v wrk=$wrk '{if (tim * wrk > 0) printf "%f", $1 / (tim * wrk); else printf X}'
		done|$(dirname $0)/avg.sh 1|cut -f2 -d' ')
		echo $val | awk '{if ($1 < 100) {printf "%8.2f", $1} else {printf "%8.0f", $1} }'
		$perf_ipc && case $c in
			cycles) cycles=$val;;
			instructions) [ "$cycles" != "X" ] && echo $cycles $val|awk '{if ($1 > 0) printf "%8.2f", $2 / $1; else printf "%8s", X}' || printf "%8s" X;;
			*) ;;
		esac
	done | ($PERCENT && awk '{printf "%8.0f%8.0f%8.2f%8.2f%8.2f%8.2f%8.2f%8.2f%8.0f%8.2f", $1, $2, $3, 100*$4/$9, 100*$5/$9, 100*$6/$9, 100*$7/$9, 100*$8/$9, $9, 100*($4+$5+$6+$7+$8)/$9}' || cat)
}

case $OUTPUT in
	table)
		for t in $TC; do
			$RAW || {
				echo $t
				printf "%6s" load; print_headers
			}
			for q in $QPS; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%6s" $s
				print_qps; print_avglat; print_95lat; print_99lat; print_cpu; print_ppi; print_perf_perq
				echo
			done; $RAW || echo
		done;;
	qtable)
		[ $# -gt 0 ] && SORT="sort -n -k $1" || SORT="cat"
		for q in $QPS; do
			$RAW || {
				printf "%10s%6s" testcase load; print_headers
			}
			for t in $TC; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%10s%6s" $t $s
				print_qps; print_avglat; print_95lat; print_99lat; print_cpu; print_ppi; print_perf_perq
				echo
			done|$SORT; $RAW || echo
		done;;
	rtable)
		for t in $TC; do
			echo $t
			printf "%6s" load; for q in $QPS; do
				[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
				printf "%8s" $s
			done;echo
			printf "%6s" qps;    for q in $QPS; do print_qps;    done;echo
			printf "%6s" avglat; for q in $QPS; do print_avglat; done;echo
			printf "%6s" 95%lat; for q in $QPS; do print_95lat;  done;echo
			printf "%6s" 99%lat; for q in $QPS; do print_99lat;  done;echo
			printf "%6s" cpu;    for q in $QPS; do print_cpu;    done;echo
			printf "%6s" ppi;    for q in $QPS; do print_ppi;    done;echo
			echo
		done;;
	qps)
		printf "\n%5s %12s" qps testcase; printf "%18s %18s %6s %18s %6s\n\n" avg std cov med spread
		for q in $QPS; do for t in $TC; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%5s %12s" $s $t; getnumber $*|awk '{printf "%18.3f %18.3f %6.3f %18.3f %6.3f\n", $2, $4, $5, $6, $7}'
		done|$SORT; echo; done;;
	tc)
		printf "\n%12s %5s" testcase qps; printf "%18s %18s %6s %18s %6s\n\n" avg std cov med spread
		for t in $TC; do for q in $QPS; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%12s %5s" $t $s; getnumber $*|awk '{printf "%18.3f %18.3f %6.3f %18.3f %6.3f\n", $2, $4, $5, $6, $7}'
		done; echo; done;;
	xpq)
		printf "\n%5s %12s" qps testcase; printf "%18s %18s %6s %18s %6s\n\n" avg std cov med spread
		for q in $QPS; do for t in $TC; do
			[ $q -eq 0 ] && s=MAX || s=$(($q/1000))K
			printf "%5s %12s" $s $t
			for r in $(ls mutilate-$q-$t-*.out|cut -f4 -d-|cut -f1 -d.); do
				wrk=$(grep -Fh QPS mutilate-$q-$t-$r.out|awk '{print $4}')
				cnt=$(grep -Fh $COUNT perf-$q-$t-$r.out|awk '{print $1}')
				tim=$(grep -A10 $COUNT perf-$q-$t-$r.out|grep -F elapsed|awk '{print $1}')
				[ -z "$wrk" ] || echo $cnt $tim $wrk | awk '{printf "%18.3f\n", $1 / ($2 * $3)}'
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
process.sh -c epoll mc-worker 7 10  # average epoll return count, takes long time
process.sh -c poll @ 2 4            # average napi poll count, takes long time

process.sh -c mutilate QPS 4        # throughput, by TC, then load

process.sh -t   # table by tc:  load in y, result in x
process.sh -r   # table by tc:  load in x, result in y
process.sh -q 5 # table by qps: tc in x, result in y, sorted by 99%lat

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
