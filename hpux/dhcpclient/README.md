# dhcpclient: DHCP for HP-UX 9

HP-UX 9 ships no DHCP client. This is a small one for the HP9K385 core, or
any HP 9000 Series 300/400 running HP-UX 9 with a LAN card.

| File | What |
|---|---|
| `dhcpclient.c` | The client. Broadcasts DISCOVER and REQUEST with the broadcast flag. On ACK it prints the address, netmask, router, lease and server, then the DNS servers and domain. Build with `c89 -o dhcpclient dhcpclient.c`. |
| `dhcpclient` | Prebuilt for HP-UX 9.10, Series 300 (68040; `HP s200 pure executable`). |
| `dhcpclient.sh` | The boot script, installed as `/etc/dhcpclient.sh`. It sets `lan0`'s address, netmask and default route, maps this host's name to the address in `/etc/hosts`, writes `/etc/resolv.conf`, and renews at half the lease. |
| `install.sh` | Installs the files, hooks `/etc/netlinkrc` (one marked line after `lo0`), optionally renames the system, and takes a lease. |
| `remove.sh` | Undoes all of it, restoring the originals that `install.sh` kept. |

## Install

Copy this directory to the machine, for example over telnet or FTP once `lan0` has an address. Then, as root:

```sh
cd dhcpclient
sh install.sh hp385      # the name is optional; without it the name is kept
```

`/etc/hosts` must map the current host name to some address, because
`netlinkrc` starts `lan0` with ``ifconfig lan0 inet `hostname` `` before the
hook runs. `install.sh` and every lease keep that entry current.

Originals are kept as `*.pre-dhcpclient`, and `/etc/resolv.conf` as `/etc/resolv.conf.orig`.

## Remove

```sh
sh remove.sh
```
