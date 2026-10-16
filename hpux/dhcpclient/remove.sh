#!/bin/sh
# remove.sh - undo install.sh (run as root).  Takes the hook out of
# /etc/netlinkrc, removes the binary and boot script, stops lease renewal,
# and puts back the originals install.sh kept (*.pre-dhcpclient:
# /etc/src.sh, /etc/hosts, /usr/adm/inetd.sec) and /etc/resolv.conf.orig.
# lan0 keeps its current address until the next boot.
PATH=/bin:/usr/bin:/etc; export PATH

if grep '# dhcpclient begin' /etc/netlinkrc >/dev/null 2>&1; then
	awk '/^# dhcpclient begin/ { skip = 1 } !skip { print } /^# dhcpclient end/ { skip = 0 }' \
		/etc/netlinkrc > /tmp/nl.$$ && cp /tmp/nl.$$ /etc/netlinkrc
	rm -f /tmp/nl.$$
	echo "/etc/netlinkrc: hook removed"
fi
rm -f /etc/netlinkrc.pre-dhcpclient

# the renewal loop runs as "sh /etc/dhcpclient.sh"
for p in `ps -ef | awk '/dhcpclient\.sh/ && !/awk/ { print $2 }'`; do kill $p 2>/dev/null; done
rm -f /etc/dhcpclient.sh /usr/local/bin/dhcpclient

for f in /etc/src.sh /etc/hosts /usr/adm/inetd.sec; do
	if [ -f $f.pre-dhcpclient ]; then
		cp -p $f.pre-dhcpclient $f && rm -f $f.pre-dhcpclient
		echo "$f: restored"
	fi
done
if [ -f /etc/resolv.conf.orig ]; then
	cp -p /etc/resolv.conf.orig /etc/resolv.conf && rm -f /etc/resolv.conf.orig
	echo "/etc/resolv.conf: restored"
fi
echo "removed; the system name and lan0 address change back at the next boot"
