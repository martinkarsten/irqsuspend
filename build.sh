#!/bin/bash
usage() {
	echo "$0 [options] <target> [<build host>] [<scp helper>]"; exit 1
	echo "Options:"
  echo "-b build (compile with lock)"
  echo "-c compile"
  echo "-C clean first"
  echo "-d distclean first"
  echo "-i install"
  echo "-p prepare"
}

opt_build=false
opt_compile=false
opt_clean=false
opt_distclean=false
opt_install=false
opt_prep=false
opt_wait=false

while getopts "bcCdipw" option; do
case $option in
	b) opt_build=true;;
	c) opt_compile=true;;
	C) opt_clean=true;;
	d) opt_distclean=true;;
	i) opt_install=true;;
	p) opt_prep=true;;
	w) opt_wait=true;;
	*) usage;;
esac; done

[ $OPTIND -eq 1 ] && {
	opt_prep=true
	opt_build=true
	opt_install=true
	opt_wait=true
} || {
	shift $(($OPTIND - 1))
}

[ $# -gt 0 ] && target=$1 || usage
[ $# -gt 1 ] && buildhost=$2 || buildhost=kosa64
[ $# -gt 2 ] && scphelper=$3 || scphelper=kalli

dir=$(dirname $0)

$opt_prep && {
	files=$dir/setup.sh
	[ -f $dir/servercfg/setup_$target.sh ] && files+=" $dir/servercfg/setup_$target.sh"
	scp $files $target:
}

$opt_clean && {
	ssh -t $buildhost "make -C linux/net-next clean"
}

$opt_distclean && {
	ssh -t $buildhost "make -C linux/net-next distclean"
}

$opt_build && {
	$opt_clean && cleanflag="-C" || unset cleanflag
	echo "getting lock"
	flock -F $TMPDIR/build.$buildhost $0 -c $cleanflag $target $buildhost $scphelper || exit 1
}

$opt_compile && {
	ssh -t $buildhost "[ -f config.$target ] && cp config.$target linux/net-next/.config && echo|make -C linux/net-next oldconfig" || exit 1
	ssh -t $buildhost "sed -i -e 's/CONFIG_DEBUG_INFO;/CONFIG_DEBUG_INFO_XXX;/' linux/net-next/scripts/package/mkdebian"
	ssh -t $buildhost 'rm -f linux/*.deb linux/linux-upstream*; make -C linux/net-next -j $(nproc) LOCALVERSION=-test bindeb-pkg' || exit 1
	[ "$HOSTNAME" = "$scphelper" ] && unset SCPHOST || SCPHOST="ssh -t $scphelper"
	ssh -t $target 'rm -f linux/*.deb'; $SCPHOST scp $buildhost:linux/linux-{headers,image}-*.deb $target:linux/ || exit 1
}

$opt_install && {
	ssh -t $target 'uname -r|grep -Fq test && sudo apt purge $(apt list --installed|grep -F $(uname -r)|cut -f1 -d/) -y'
	ssh -t $target 'sudo dpkg -i linux/linux-{headers,image}-*.deb && sudo grub-reboot 0 && sudo reboot || exit 1' || exit 1
}

$opt_wait && {
	echo "waiting for $target reboot"
	until ssh -t -oPasswordAuthentication=no $target ./setup.sh boot 2>/dev/null; do sleep 3; done
}

exit 0
