#!/bin/sh
# install.sh - install the DHCP client on HP-UX 9 (run as root from this
# directory).
#
#   sh install.sh [HOSTNAME]
#
#  - /usr/local/bin/dhcpclient: the prebuilt binary, or built here with c89
#    if it is missing;
#  - /etc/dhcpclient.sh: the boot script (lan0 address, netmask, default
#    route, /etc/hosts entry for this host, /etc/resolv.conf, lease renewal);
#  - /etc/netlinkrc: one marked line after lo0 is configured runs it at
#    boot (the original is kept as /etc/netlinkrc.pre-dhcpclient);
#  - with HOSTNAME: renames the system (SYSTEM_NAME in /etc/src.sh, the
#    running hostname/uname, /etc/hosts and /usr/adm/inetd.sec); the
#    originals are kept as *.pre-dhcpclient;
#  - then takes a lease now.
# remove.sh undoes all of it.
PATH=/bin:/usr/bin:/etc:/usr/local/bin; export PATH
cd `dirname $0` || exit 1

if [ ! -f dhcpclient.c ] || [ ! -f dhcpclient.sh ]; then
	echo "install.sh: run it from the dhcpclient directory"; exit 1
fi

keep() {        # keep the first original of a file
	[ -f "$1" ] && [ ! -f "$1.pre-dhcpclient" ] && cp -p "$1" "$1.pre-dhcpclient"
}

# ---- the binary and the boot script ----
mkdir -p /usr/local/bin
if [ ! -x dhcpclient ]; then
	echo "building dhcpclient with c89"
	c89 -o dhcpclient dhcpclient.c || exit 1
fi
cp dhcpclient /usr/local/bin/dhcpclient && chmod 755 /usr/local/bin/dhcpclient
cp dhcpclient.sh /etc/dhcpclient.sh && chmod 755 /etc/dhcpclient.sh

# ---- rename ----
NEW=$1
OLD=`hostname`
if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then
	echo "renaming $OLD -> $NEW"
	keep /etc/src.sh
	sed "s/^SYSTEM_NAME=[^ ;]*/SYSTEM_NAME=$NEW/" /etc/src.sh > /tmp/src.$$ && cp /tmp/src.$$ /etc/src.sh
	rm -f /tmp/src.$$
	for f in /etc/hosts /usr/adm/inetd.sec; do
		[ -f $f ] || continue
		keep $f
		awk '{ for (i = 1; i <= NF; i++) if ($i == o) $i = n; else if ($i == o ".") $i = n "."; print }' \
			o="$OLD" n="$NEW" $f > /tmp/ren.$$ && cp /tmp/ren.$$ $f
		rm -f /tmp/ren.$$
	done
	hostname $NEW
	uname -S $NEW
fi

# ---- /etc/netlinkrc ----
if grep '# dhcpclient begin' /etc/netlinkrc >/dev/null 2>&1; then
	echo "/etc/netlinkrc already runs dhcpclient"
else
	keep /etc/netlinkrc
	awk '
		!done && /^# The x25init/ {
			print "# dhcpclient begin (hpux/dhcpclient; remove.sh takes this out)"
			print "[ -x /etc/dhcpclient.sh ] && /etc/dhcpclient.sh"
			print "# dhcpclient end"
			done = 1
		}
		{ print }
		END { if (!done) exit 1 }' /etc/netlinkrc > /tmp/nl.$$ || {
		echo "install.sh: no place for the hook in /etc/netlinkrc (add: /etc/dhcpclient.sh)"
		rm -f /tmp/nl.$$; exit 1; }
	cp /tmp/nl.$$ /etc/netlinkrc; rm -f /tmp/nl.$$
	echo "/etc/netlinkrc: runs /etc/dhcpclient.sh at boot"
fi

# ---- a lease now ----
/etc/dhcpclient.sh
