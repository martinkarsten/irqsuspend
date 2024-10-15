SERVER=$1
MEMCACHED="work/memcached/memcached"; MUTILATE="mutilate"; PERF="/usr/local/perf/bin/perf"; FGDIR="~/work/FlameGraph"
NDCLI="linux/net-next/tools/net/ynl/cli.py --no-schema --output-json --spec linux/net-next/Documentation/netlink/specs/netdev.yaml"
case $SERVER in
	tilly01|node10)
		COALESCEd=" on  on  8 128 na na  8 128 na na  on off" # default
		COALESCE1="off off  8 128 na na  8 128 na na  on off" # Adaptive RX/TX off
		COALESCE0="off off  0   1 na na  0   1 na na off off" # all coalescing off
		;;
	mlx4|red01|red01vm|tilly02)
		COALESCEd=" on  na 16  44 na na 16  16 na 256 na  na" # default
		COALESCE1="off  na 16  44 na na 16  16 na 256 na  na" # Adaptive RX/TX off
		COALESCE0="off  na  0   1 na na  0   1 na 256 na  na" # all coalescing off
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
	tilly01) # mlx5
		IFACE=ens2f1np1; SERVER_IP=192.168.199.1; DRIVER=tilly02; CLIENTS=tilly03,tilly04,tilly05,tilly06,tilly07,tilly08
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=16; MUTCORES=16; QPS="200000 400000 600000 800000"
		;;
	mlx4)
		SERVER=tilly01
		IFACE=eno3d1; SERVER_IP=192.168.199.1; DRIVER=tilly02; CLIENTS=tilly03,tilly04,tilly05,tilly06,tilly07,tilly08
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=16; MUTCORES=16; QPS="200000 400000 600000 800000"
		;;
	tilly02) # mlx4
		IFACE=eno3d1; SERVER_IP=192.168.199.2; DRIVER=tilly01; CLIENTS=tilly03,tilly04,tilly05,tilly06,tilly07,tilly08
		BASECORE=0; MAXCORES=8; OTHER="8-15"; HTBASE=16; MUTCORES=16; QPS="200000 400000 600000 800000"
		;;
	node10)
		IFACE=ens1np0; SERVER_IP=192.168.126.110; DRIVER=node01; CLIENTS=node03,node04,node05,node06,node07,node08
		BASECORE=0; MAXCORES=8; OTHER="8-9"; HTBASE=10; MUTCORES=10; QPS="200000 400000 600000 800000 1000000"
		MUTILATE="./mutilate"
		;;
	*)
		echo unknown server $SERVER; exit 1;;
esac
