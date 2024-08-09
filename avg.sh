#!/bin/bash

usage() {
	echo "usage: $0 <column> [<weight>]" >&2
	exit 1
}

AWKSCRIPT="BEGIN {
	min  =   2^(PREC-1)
	max  = - 2^(PREC-1)
	sum  = 0
	sum2 = 0
	cnt  = 0
}

{
	v=\$column
	if (weight > 0) w=\$weight
	else w=1
	if (v > max) { max = v }
	if (v < min) { min = v }
	sum += (v*w)
	sum2 += (v*v*w)
	cnt += w
}

END {
	if (cnt > 0) {
		avg = sum/cnt
		if (sum2/cnt > avg*avg) stddev = sqrt(sum2/cnt - avg*avg)
		else stddev = 0
		if (avg > 0) cov = stddev/avg
		else cov = 0
		printf \"%.3f %.3f %.3f %.3f %.3f %.3f (min,avg,max,std,cov,sum)\\n\", min, avg, max, stddev, cov, sum
	} else {
		printf \"X X X X X X\\n\"
	}
}"

[ $# -ge 1 ] || usage
[ $# -gt 1 ] && w=$2 || w=0
exec awk -v column=$1 -v weight=$w -- "${AWKSCRIPT}"