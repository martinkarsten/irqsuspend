SERVER=$1
MEMCACHED="work/memcached/memcached"; MUTILATE="./mutilate"; PERF="/usr/local/perf/bin/perf"; FGDIR="~/work/FlameGraph"
NDCLI="linux/net-next/tools/net/ynl/pyynl/cli.py --no-schema --output-json --spec linux/net-next/Documentation/netlink/specs/netdev.yaml"
case $SERVER in
	red01|red01vm) # mlx4
		COALESCEd=" on  na 16  44 na na 16  16 na 256 na  na" # default
		COALESCEx="off  na  0  44 na na 16  16 na 256 na  na" # RX coalescing off
		;;
	tilly01|tilly01vm|node10) # mlx5
		COALESCEd=" on  on  8 128 na na  8 128 na na  on off" # default
		COALESCEx="off  on  0   1 na na  8 128 na na off off" # RX coalescing off
		;;
	husky10) # ice
		COALESCEd=" on  on 50  na na na 50  na na na  na  na" # default
		COALESCEx="off  on  0  na na na 50  na na na  na  na" # RX coalescing off
		;;
esac
case $SERVER in
	red01)
		IFACE=enp130s0; SERVER_IP=10.10.0.1; DRIVER=red02; CLIENTS=red03,red04,red05,red06,red08,red09
		BASECORE=0; MAXCORES=4; OTHER="6-11"; HTBASE=12; MUTCORES=12; QPS="100000 150000 200000 250000"
		;;
	red01vm)
		IFACE=enp7s0; SERVER_IP=10.10.0.1; DRIVER=red02; CLIENTS=red03,red04,red05,red06,red08,red09
		BASECORE=0; MAXCORES=4; OTHER="5-6"; HTBASE=0; MUTCORES=12; QPS="100000 150000 200000"
		;;
	tilly01)
		IFACE=ens2f0np0; SERVER_IP=192.168.199.1; DRIVER=tilly02; CLIENTS=tilly03,tilly04,tilly05,tilly06,tilly07,tilly08
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=16; MUTCORES=16; QPS="200000 400000 600000"
		;;
	tilly01vm)
		IFACE=enp7s0; SERVER_IP=192.168.199.9; DRIVER=tilly02; CLIENTS=tilly03,tilly04,tilly05,tilly06,tilly07,tilly08
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=0; MUTCORES=16; QPS="200000 400000 600000"
		;;
	node10)
		IFACE=ens1np0; SERVER_IP=192.168.126.110; DRIVER=node01; CLIENTS=node03,node04,node05,node06,node07,node08
		BASECORE=0; MAXCORES=8; OTHER="8-9"; HTBASE=10; MUTCORES=10; QPS="200000 400000 600000 800000 1000000"
		MUTILATE="./mutilate"
		;;
	husky10)
		IFACE=enp2s0f0np0; SERVER_IP=192.168.195.30; DRIVER=husky00; CLIENTS=husky02,husky04,husky06,husky07,husky09
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=0; MUTCORES=16; QPS="200000 400000 600000"
		;;
	*)
		echo unknown server $SERVER; exit 1;;
esac
