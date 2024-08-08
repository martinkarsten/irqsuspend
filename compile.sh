#!/bin/bash
usage() {
	echo "$0 [full] <target> <build host> <scp helper>"; exit 1
}

[ "$1" = "full" ] && { FULL=true; shift; } || FULL=false
[ $# -lt 3 ] && usage
target=$1
buildhost=$2
scphelper=$3

$FULL && ssh -t $buildhost "diff -q config.$target linux/net-next/.config || { make -C linux/net-next distclean; cp config.$target linux/net-next/.config; }"
ssh -t $buildhost 'rm -f linux/*.deb linux/linux-upstream*; echo|make -C linux/net-next oldconfig' || exit 1
ssh -t $buildhost "sed -i -e 's/CONFIG_DEBUG_INFO;/CONFIG_DEBUG_INFO_XXX;/' linux/net-next/scripts/package/mkdebian"
ssh -t $buildhost 'make -C linux/net-next -j $(nproc) LOCALVERSION=-test bindeb-pkg' || exit 1
[ "$HOSTNAME" = "$scphelper" ] && unset SCPHOST || SCPHOST="ssh -t $scphelper"
ssh -t $target 'rm -f linux/*.deb'; $SCPHOST scp $buildhost:linux/linux-{headers,image}-*.deb $target:linux/ || exit 1

exit 0
