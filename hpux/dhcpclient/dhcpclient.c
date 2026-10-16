/*
 * dhcpclient - minimal DHCP client for HP-UX 9 (no DHCP client ships with it).
 *
 *   dhcpclient MAC [HOSTNAME]        MAC as 080009385001 or 0x080009385001
 *
 * Broadcasts DISCOVER and REQUEST from port 68 with the broadcast flag set,
 * so the server's replies come back to 255.255.255.255:68 and the interface
 * only has to be up (any address).  On an ACK it prints one line:
 *
 *   IP NETMASK ROUTER LEASE_SECONDS SERVER
 *
 * then, if the server sent them, DNS server addresses and the domain:
 *
 *   IP NETMASK ROUTER LEASE_SECONDS SERVER
 *   DNS a.b.c.d [e.f.g.h ...]
 *   DOMAIN name
 *
 * and exits 0; the caller (dhcpclient.sh) configures lan0 and /etc/resolv.conf.
 * Exit 1 on failure.
 * Build: c89 -o dhcpclient dhcpclient.c
 */
#if defined(__hpux) || defined(hpux)
#ifndef _HPUX_SOURCE
#define _HPUX_SOURCE            /* c89 is strict ANSI: BSD sockets need this */
#endif
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>

#define DISCOVER 1
#define OFFER    2
#define REQUEST  3
#define ACK      5
#define NAK      6

static unsigned char mac[6];
static unsigned char pkt[576];
static unsigned char rx[1600];
static unsigned long xid;
static char *hostname = 0;

static unsigned long yiaddr, mask, router, lease, server;
static unsigned long dns[4];
static int ndns;
static char domain[256];

static int hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static void put32(unsigned char *p, unsigned long v)
{
	p[0] = (v >> 24) & 255; p[1] = (v >> 16) & 255; p[2] = (v >> 8) & 255; p[3] = v & 255;
}

static unsigned long get32(unsigned char *p)
{
	return ((unsigned long)p[0] << 24) | ((unsigned long)p[1] << 16) | ((unsigned long)p[2] << 8) | p[3];
}

static int build(int type, unsigned long req_ip, unsigned long srv)
{
	unsigned char *o;
	int n;

	memset(pkt, 0, sizeof pkt);
	pkt[0] = 1; pkt[1] = 1; pkt[2] = 6;      /* BOOTREQUEST, Ethernet */
	put32(pkt + 4, xid);
	pkt[10] = 0x80;                          /* broadcast flag */
	memcpy(pkt + 28, mac, 6);
	put32(pkt + 236, 0x63825363UL);          /* magic cookie */
	o = pkt + 240;
	*o++ = 53; *o++ = 1; *o++ = type;
	*o++ = 61; *o++ = 7; *o++ = 1; memcpy(o, mac, 6); o += 6;
	if (type == REQUEST) {
		*o++ = 50; *o++ = 4; put32(o, req_ip); o += 4;
		*o++ = 54; *o++ = 4; put32(o, srv); o += 4;
	}
	if (hostname && (n = strlen(hostname)) > 0 && n < 64) {
		*o++ = 12; *o++ = n; memcpy(o, hostname, n); o += n;
	}
	*o++ = 55; *o++ = 6; *o++ = 1; *o++ = 3; *o++ = 6; *o++ = 15; *o++ = 51; *o++ = 54;
	*o++ = 255;
	n = o - pkt;
	return n < 300 ? 300 : n;
}

/* parse a reply for our xid; returns its DHCP message type or 0 */
static int parse(int len)
{
	unsigned char *o, *end;
	int type = 0;

	if (len < 240 || rx[0] != 2 || get32(rx + 4) != xid || memcmp(rx + 28, mac, 6) != 0)
		return 0;
	if (get32(rx + 236) != 0x63825363UL) return 0;
	yiaddr = get32(rx + 16);
	o = rx + 240; end = rx + len;
	while (o < end && *o != 255) {
		int code = *o++, l;
		if (code == 0) continue;
		if (o >= end) break;
		l = *o++;
		if (o + l > end) break;
		switch (code) {
		case 53: if (l >= 1) type = o[0]; break;
		case 1:  if (l >= 4) mask = get32(o); break;
		case 3:  if (l >= 4) router = get32(o); break;
		case 51: if (l >= 4) lease = get32(o); break;
		case 54: if (l >= 4) server = get32(o); break;
		case 6:
			for (ndns = 0; ndns < 4 && ndns * 4 + 4 <= l; ndns++) dns[ndns] = get32(o + ndns * 4);
			break;
		case 15:
			memcpy(domain, o, l); domain[l] = 0;
			break;
		}
		o += l;
	}
	return type;
}

static int exchange(int s, int len, int want)
{
	struct sockaddr_in to;
	int tries, t;

	memset(&to, 0, sizeof to);
	to.sin_family = AF_INET;
	to.sin_port = htons(67);
	to.sin_addr.s_addr = htonl(0xFFFFFFFFUL);
	for (tries = 0; tries < 6; tries++) {
		if (sendto(s, (char *)pkt, len, 0, (struct sockaddr *)&to, sizeof to) < 0) {
			perror("dhcpclient: sendto");
			return 0;
		}
		for (t = 0; t < 4; t++) {           /* up to ~4 s for a reply */
			fd_set fds;
			struct timeval tv;
			int n;
			FD_ZERO(&fds); FD_SET(s, &fds);
			tv.tv_sec = 1; tv.tv_usec = 0;
			if (select(s + 1, (int *)&fds, 0, 0, &tv) <= 0) continue;
			n = recv(s, (char *)rx, sizeof rx, 0);
			if (n > 0) {
				int type = parse(n);
				if (type == want) return type;
				if (type == NAK) return NAK;
			}
		}
	}
	return 0;
}

static void ipstr(unsigned long a, char *b)
{
	sprintf(b, "%lu.%lu.%lu.%lu", (a >> 24) & 255, (a >> 16) & 255, (a >> 8) & 255, a & 255);
}

int main(int argc, char **argv)
{
	struct sockaddr_in me;
	struct timeval now;
	char *m;
	int s, i, on = 1, len;
	unsigned long offer_ip, offer_srv;
	char a[20], b[20], c[20], d[20];

	if (argc < 2) {
		fprintf(stderr, "usage: dhcpclient MAC [HOSTNAME]\n");
		return 1;
	}
	m = argv[1];
	if (m[0] == '0' && (m[1] == 'x' || m[1] == 'X')) m += 2;
	for (i = 0; i < 6; i++) {
		int h, l;
		while (*m == ':' || *m == '-') m++;
		h = hexval(m[0]); l = h < 0 ? -1 : hexval(m[1]);
		if (h < 0 || l < 0) { fprintf(stderr, "dhcpclient: bad MAC\n"); return 1; }
		mac[i] = h * 16 + l; m += 2;
	}
	if (argc > 2) hostname = argv[2];
	gettimeofday(&now, 0);
	xid = ((unsigned long)now.tv_sec << 8) ^ now.tv_usec ^ ((unsigned long)mac[4] << 8) ^ mac[5];

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) { perror("dhcpclient: socket"); return 1; }
	setsockopt(s, SOL_SOCKET, SO_BROADCAST, (char *)&on, sizeof on);
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (char *)&on, sizeof on);
	memset(&me, 0, sizeof me);
	me.sin_family = AF_INET;
	me.sin_port = htons(68);
	me.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(s, (struct sockaddr *)&me, sizeof me) < 0) { perror("dhcpclient: bind"); return 1; }

	len = build(DISCOVER, 0, 0);
	if (exchange(s, len, OFFER) != OFFER) { fprintf(stderr, "dhcpclient: no offer\n"); return 1; }
	offer_ip = yiaddr; offer_srv = server;
	len = build(REQUEST, offer_ip, offer_srv);
	if (exchange(s, len, ACK) != ACK) { fprintf(stderr, "dhcpclient: no ack\n"); return 1; }

	if (!mask) mask = 0xFFFFFF00UL;
	ipstr(yiaddr, a); ipstr(mask, b); ipstr(router, c); ipstr(server, d);
	printf("%s %s %s %lu %s\n", a, b, c, lease, d);
	if (ndns > 0) {
		printf("DNS");
		for (i = 0; i < ndns; i++) { ipstr(dns[i], a); printf(" %s", a); }
		printf("\n");
	}
	if (domain[0]) printf("DOMAIN %s\n", domain);
	return 0;
}
