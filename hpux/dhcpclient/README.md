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

## How it gets a first lease anywhere

HP-UX 9 makes the first request awkward:
- `ifconfig` won't set the address 0.0.0.0.
- The stack routes even 255.255.255.255 through a default gateway, if there is one.
- It rewrites that destination to the interface's broadcast address.

So the boot script removes default routes first. Then `dhcpclient -z` sets `lan0` to 0.0.0.0 and its broadcast address to 255.255.255.255 through the ioctls, and the requests go out as a normal DHCP client's do: from 0.0.0.0 to 255.255.255.255. That works whatever address `/etc/hosts` gave `lan0` at boot. Without a lease, the old address is put back.

## Install

Copy this directory to the machine, for example over telnet or FTP once `lan0` has an address. Then, as root:

```sh
cd dhcpclient
sh install.sh hp385      # the name is optional; without it the name is kept
```

`/etc/hosts` must map the current host name to some address, because
`netlinkrc` starts `lan0` with ``ifconfig lan0 inet `hostname` `` before the
hook runs. `install.sh` and every lease keep that entry current.

Originals are kept as `*.pre-dhcpclient`, and `/etc/resolv.conf` as `/etc/resolv.conf.orig`. On a short-filename (14-character) file system these names are truncated, for example to `hosts.pre-dhcp`. HP-UX truncates the same way on lookup, so `remove.sh` still finds them.

## Remove

```sh
sh remove.sh
```
