#!/bin/bash
usage() {
	echo "$0 [full] <target> [<build host>] [<scp helper>]"; exit 1
}

[ "$1" = "full" ] && { FULL="full"; shift; } || FULL=""

[ $# -gt 0 ] && target=$1 || usage
[ $# -gt 1 ] && buildhost=$2 || buildhost=kosa64
[ $# -gt 2 ] && scphelper=$3 || scphelper=kalli

dir=$(dirname $0)
files=$dir/setup.sh
[ -f $dir/servercfg/setup_$target.sh ] && files+=" $dir/servercfg/setup_$target.sh"
scp $files $target:

echo "getting lock"
flock -F $TMPDIR/build.$buildhost $dir/compile.sh $FULL $target $buildhost $scphelper || exit 1

ssh -t $target 'uname -r|grep -Fq test && sudo apt purge $(apt list --installed|grep -F $(uname -r)|cut -f1 -d/) -y'
ssh -t $target 'sudo dpkg -i linux/linux-{headers,image}-*.deb && sudo grub-reboot 0 && sudo reboot || exit 1'
[ $? -eq 1 ] && exit 1
until ssh -t -oPasswordAuthentication=no $target ./setup.sh 2>/dev/null; do sleep 3; done
exit 0
