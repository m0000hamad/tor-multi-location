# tor-multi-location

Run many Tor clients on one Linux server, each pinned to a different exit
country, and get one SOCKS5 port per country.

```
NAME     CC  PORT   RESULT EXIT IP           GEO  LATENCY
de       de  9100   ok     185.220.101.102   de   1954ms
nl       nl  9101   ok     192.42.116.106    nl   2010ms
nl2      nl  9102   ok     192.42.116.112    nl   1486ms
```

## Install

Debian 11+ or Ubuntu 22.04+ with systemd, as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m0000hamad/tor-multi-location/main/tor-geo.sh) install
```

Then run `tor-geo` for the menu, or use the commands below.

## Usage

```bash
tor-geo countries          # countries that have Tor exit relays right now
tor-geo add de nl us       # one node per country
tor-geo add nl:3           # three Netherlands nodes (different IPs)
tor-geo add --top 10       # the 10 countries with the most exits
tor-geo list               # nodes, ports, state, last exit IP
tor-geo check              # probe every node now: exit IP, country, latency
tor-geo rotate de          # restart a node for new circuits / new IP
tor-geo remove nl2         # remove one node (or a country code, or 'all')
tor-geo logs de            # Tor log of one node
tor-geo export             # socks5:// URL of every node
tor-geo xray               # Xray outbounds + routing rules as JSON
```

Each node is a separate `tor` process (`systemctl status tor-geo@de`) with
`ExitNodes {de}` and `StrictNodes 1`. A systemd timer probes every node every 5
minutes and restarts any node that fails two probes in a row.

## Using the ports

By default every port listens on `127.0.0.1` only. Pick one of:

**1. Xray / Marzban / PasarGuard / 3x-ui on the same server** (recommended).
`tor-geo xray` prints one `socks` outbound per node (`tor-de`, `tor-nl`, …) and
a routing rule that sends inbound `in-de` to outbound `tor-de`. Merge both into
the core config and create one inbound per country with the matching tag. Users
then pick a location by picking a config. Change the inbound tag prefix with
`tor-geo xray myprefix-`.

**2. SSH tunnel from your own computer**:

```bash
ssh -N -L 9100:127.0.0.1:9100 root@SERVER
```

then use `socks5://127.0.0.1:9100` locally.

**3. Open the ports to your own IP only**:

```bash
tor-geo expose 1.2.3.4          # your IP or CIDR; several allowed
tor-geo unexpose                # back to local only
```

The ports then listen on `0.0.0.0`, and Tor's `SocksPolicy` rejects every
client not on the list. Exposing to everyone is refused on purpose: an open
SOCKS proxy is found by scanners within hours and gets your server reported
for abuse.

## Server cannot reach Tor (e.g. a server inside Iran)

Add bridges from [bridges.torproject.org](https://bridges.torproject.org) or
the Telegram bot `@GetBridgesBot`:

```bash
tor-geo bridges            # opens /etc/tor-geo/bridges.txt, one obfs4 line each
tor-geo bridges clear
```

`obfs4` bridges use `lyrebird` or `obfs4proxy`, installed automatically when
the distro has them. `snowflake` works if `snowflake-client` is installed.

## Good to know

- Countries with few exit relays (check `tor-geo countries`) are slow and
  repeat the same IPs. Germany, Netherlands, US, France, Switzerland, Sweden
  and Finland have the most. `add` refuses countries with no exits at all
  unless you pass `--force`.
- Exit IPs are public Tor exits: Google, Cloudflare and many banks show
  captchas or block them. That comes with Tor, not with this script.
- Tor carries TCP only. No UDP, so no QUIC, no voice/video calls.
- Each node uses about 100 MB RAM (measured with Tor 0.4.9). Plan around
  1 GB for 10 nodes, 5 GB for 50.
- The first start of a node downloads the Tor directory and can take a few
  minutes on a slow link. Restarts are faster.
- `tor-geo check` reports the country from Tor's own GeoIP database, the same
  one `ExitNodes` uses, so it confirms the pinning works without calling an
  external API.

## Files

| Path | What |
|------|------|
| `/usr/local/bin/tor-geo` | the script |
| `/etc/tor-geo/tor-geo.conf` | settings (bind address, allow-list, base port, probe timeout) |
| `/etc/tor-geo/nodes/<name>.torrc` | one generated torrc per node |
| `/etc/tor-geo/bridges.txt` | optional bridges |
| `/var/lib/tor-geo/<name>/` | Tor data directory per node |
| `/etc/systemd/system/tor-geo@.service` | instance unit |
| `/etc/systemd/system/tor-geo-heal.{service,timer}` | health check |

After editing `tor-geo.conf` by hand, run `tor-geo regen`.

## Update / remove

```bash
tor-geo update
tor-geo uninstall          # leaves the tor package installed
```

## راهنمای سریع فارسی

۱. روی سرور (Ubuntu 22+ یا Debian 11+) با root نصب کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/m0000hamad/tor-multi-location/main/tor-geo.sh) install
```

۲. ببینید کدام کشورها exit دارند: `tor-geo countries`

۳. نود بسازید، مثلاً آلمان و دو تا هلند و آمریکا: `tor-geo add de nl:2 us`

۴. تست زنده (IP خروجی، کشور، تأخیر): `tor-geo check`

۵. برای استفاده در پنل (Marzban / PasarGuard / 3x-ui): خروجی `tor-geo xray` را
در کانفیگ Xray ادغام کنید و برای هر کشور یک inbound با تگ `in-de`، `in-nl` و…
بسازید. هر کاربر با انتخاب کانفیگ، لوکیشن را انتخاب می‌کند.

۶. استفاده مستقیم از کامپیوتر خودتان: `tor-geo expose IP-شما` (پورت‌ها فقط برای
همان IP باز می‌شوند).

اگر سرور داخل ایران است و Tor وصل نمی‌شود، با `tor-geo bridges` بریج obfs4
اضافه کنید (از ربات تلگرام `@GetBridgesBot`).

## License

MIT
