#!/bin/sh
# /etc/dhcpclient.sh - configure lan0 by DHCP on HP-UX 9 (hpux/dhcpclient).
# Run from /etc/netlinkrc after lan0 is up.  Sets lan0's address, netmask
# and default route, points this host's name at the address in /etc/hosts,
# writes /etc/resolv.conf from the server's DNS and domain (the old file is
# kept once as /etc/resolv.conf.orig), then renews at half the lease.
PATH=/bin:/usr/bin:/etc:/usr/local/bin; export PATH
NAME=`hostname`
MAC=`lanscan | awk '/lan0/ { for (i = 1; i <= NF; i++) if ($i ~ /^0x/) { print $i; exit } }'`
if [ -z "$MAC" ]; then echo "dhcpclient.sh: no lan0"; exit 1; fi

lease() {
	OUT=`dhcpclient $MAC $NAME` || return 1
	set -- `echo "$OUT" | head -1`
	IP=$1; MASK=$2; GW=$3; LEASE=$4
	ifconfig lan0 inet $IP netmask $MASK up
	if [ "$GW" != "0.0.0.0" ]; then
		# replace every default route (the static set-up may have added one)
		for g in `netstat -rn | awk '$1 == "default" { print $2 }'`; do
			route delete default $g >/dev/null 2>&1
		done
		route add default $GW 1 >/dev/null
	fi
	# this host's name -> the leased address
	awk '{ keep = 1; for (i = 2; i <= NF; i++) if ($i == n) keep = 0; if (keep) print }' \
		n="$NAME" /etc/hosts > /tmp/hosts.$$
	echo "$IP	$NAME" >> /tmp/hosts.$$
	cp /tmp/hosts.$$ /etc/hosts; rm -f /tmp/hosts.$$
	# DNS
	if echo "$OUT" | grep '^DNS ' >/dev/null; then
		[ -f /etc/resolv.conf.orig ] || cp /etc/resolv.conf /etc/resolv.conf.orig 2>/dev/null
		{
			echo "$OUT" | awk '$1 == "DOMAIN" { print "domain " $2 }'
			echo "$OUT" | awk '$1 == "DNS" { for (i = 2; i <= NF; i++) print "nameserver " $i }'
		} > /etc/resolv.conf
	fi
	echo "lan0: $IP netmask $MASK router $GW lease $LEASE s"
	return 0
}

if lease; then
	# renew at half the lease, in the background
	( while :; do
		T=`expr $LEASE / 2`; [ "$T" -lt 60 ] && T=60
		sleep $T
		lease >/dev/null 2>&1 || LEASE=120
	done ) &
else
	echo "dhcpclient.sh: no DHCP lease; lan0 keeps its address"
fi
