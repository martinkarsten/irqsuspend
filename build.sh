#!/bin/bash
usage() {
	echo "$0 [options] <target> [<build host>] [<scp helper>]"
	echo "Options:"
  echo "-b build: locked(c,t)"
  echo "-c compile"
  echo "-d with debug package"
  echo "-i install and boot"
  echo "-s setup: locked(t),i,w"
  echo "-t transfer image"
  echo "-w wait for boot"
  echo "-C clean first"
  echo "-D distclean first"
	echo "default: b,i,w"
	exit 1
}

opt_build=false
opt_compile=false
opt_clean=false
opt_debug=false
opt_distclean=false
opt_install=false
opt_setup=false
opt_transfer=false
opt_wait=false

while getopts "bcCdDistw" option; do
case $option in
	b) opt_build=true;;
	c) opt_compile=true;;
	C) opt_clean=true;;
	d) opt_debug=true;;
	D) opt_distclean=true;;
	i) opt_install=true;;
	s) opt_setup=true;;
	t) opt_transfer=true;;
	w) opt_wait=true;;
	*) usage;;
esac; done

[ $OPTIND -eq 1 ] && {
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

$opt_build && {
	unset flags
	$opt_clean && flags+=" -C"
	$opt_debug && flags+=" -d"
	$opt_distclean && flags+=" -D"
	echo "getting lock"
	flock -F $TMPDIR/build.$buildhost $0 -ct $flags $target $buildhost $scphelper || exit 1
}

$opt_compile && {
	ssh $buildhost bash <<EOF
$opt_clean && make -C linux/net-next clean
$opt_distclean && make -C linux/net-next distclean
[ -f config.$target ] && cp config.$target linux/net-next/.config && echo|make -C linux/net-next oldconfig || exit 1
$opt_debug \
&& sed -i -e 's/CONFIG_DEBUG_INFO_XXX;/CONFIG_DEBUG_INFO;/' linux/net-next/scripts/package/mkdebian \
|| sed -i -e 's/CONFIG_DEBUG_INFO;/CONFIG_DEBUG_INFO_XXX;/' linux/net-next/scripts/package/mkdebian
rm -f linux/*.deb linux/linux-upstream*; make -C linux/net-next -j \$(nproc) LOCALVERSION=-test bindeb-pkg || exit 1
EOF
}

$opt_setup && {
	echo "getting lock"
	flock -F $TMPDIR/build.$buildhost $0 -t $target $buildhost $scphelper || exit 1
	opt_install=true
	opt_wait=true
}

$opt_transfer && [ "$buildhost" != "$target" ] && {
	[ "$HOSTNAME" = "$scphelper" ] && unset SCPHOST || SCPHOST="ssh $scphelper"
	ssh $target 'rm -f linux/*.deb'
	$SCPHOST scp $buildhost:linux/linux-{headers,image}-*.deb $target:linux/ || exit 1
}

$opt_install && {
	ssh $target bash <<EOF
uname -r|grep -Fq test && sudo apt purge \$(apt list --installed|grep -F \$(uname -r)|cut -f1 -d/) -y
sudo dpkg -i linux/linux-{headers,image}-*.deb || exit 1
sudo grub-reboot \$(expr \$(sudo grep -F Ubuntu /boot/grub/grub.cfg |grep -n -m 1 \$(ls linux/linux-image-*|fgrep -v dbg|cut -f1 -d_|cut -f3- -d-)|cut -f1 -d:) - 1) && sudo reboot || exit 1
EOF
}

$opt_wait && {
	echo "waiting for $target"
	sleep 1
	until ssh -oPasswordAuthentication=no $target true 2>/dev/null; do sleep 3; done
}

exit 0
