#!/usr/bin/env bash
# tor-geo — run many Tor client instances, each pinned to one exit country,
# and expose every instance as its own SOCKS5 port.
#
# Target: Debian 11+ / Ubuntu 22.04+ with systemd. Run as root.
#
#   bash tor-geo.sh install        # one-time setup, installs /usr/local/bin/tor-geo
#   tor-geo                        # interactive menu
#   tor-geo help                   # all sub-commands

set -euo pipefail

VERSION="1.1.0"
RAW_URL=https://raw.githubusercontent.com/m0000hamad/tor-multi-location/main/tor-geo.sh

BIN=/usr/local/bin/tor-geo
CONF_DIR=/etc/tor-geo
NODES_DIR=$CONF_DIR/nodes
CONF=$CONF_DIR/tor-geo.conf
BRIDGES=$CONF_DIR/bridges.txt
STATE_ROOT=/var/lib/tor-geo
RUN_DIR=/run/tor-geo
UNIT=/etc/systemd/system/tor-geo@.service
HEAL_SVC=/etc/systemd/system/tor-geo-heal.service
HEAL_TIMER=/etc/systemd/system/tor-geo-heal.timer
TOR_USER=debian-tor
GEOIP=/usr/share/tor/geoip

# Defaults; tor-geo.conf overrides them.
BIND_ADDR=127.0.0.1             # 127.0.0.1 = local only (Xray on same box, SSH tunnel)
ALLOW_IPS=""                    # space-separated IPs/CIDRs allowed when exposed
BASE_PORT=9100                  # first SOCKS port handed out
CHECK_URL=https://api.ipify.org # must return the plain exit IP
PROBE_TIMEOUT=25                # seconds per health probe
HEAL_FAILS=2                    # consecutive failed probes before a restart
BOOT_GRACE=120                  # seconds after start before heal judges a node
BOOT_LIMIT=1200                 # max seconds a node may spend bootstrapping

# shellcheck source=/dev/null
[[ -f $CONF ]] && source "$CONF"

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_D=$'\e[2m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_D="" C_0=""
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s !!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

need_root()      { [[ $EUID -eq 0 ]] || die "run as root"; }
need_installed() { [[ -f $UNIT ]] || die "not installed yet — run: bash $0 install"; }

declare -A CC_NAME=(
  [ad]=Andorra [ae]=UAE [al]=Albania [am]=Armenia [ar]=Argentina [at]=Austria
  [au]=Australia [az]=Azerbaijan [ba]=Bosnia [be]=Belgium [bg]=Bulgaria
  [br]=Brazil [by]=Belarus [ca]=Canada [ch]=Switzerland [cl]=Chile [cn]=China
  [co]=Colombia [cr]=Costa-Rica [cy]=Cyprus [cz]=Czechia [de]=Germany
  [dk]=Denmark [ee]=Estonia [eg]=Egypt [es]=Spain [fi]=Finland [fr]=France
  [gb]=United-Kingdom [ge]=Georgia [gr]=Greece [hk]=Hong-Kong [hr]=Croatia
  [hu]=Hungary [id]=Indonesia [ie]=Ireland [il]=Israel [in]=India [iq]=Iraq
  [ir]=Iran [is]=Iceland [it]=Italy [jp]=Japan [kr]=South-Korea [kz]=Kazakhstan
  [li]=Liechtenstein [lt]=Lithuania [lu]=Luxembourg [lv]=Latvia [md]=Moldova
  [me]=Montenegro [mk]=North-Macedonia [mt]=Malta [mx]=Mexico [my]=Malaysia
  [ng]=Nigeria [nl]=Netherlands [no]=Norway [nz]=New-Zealand [pa]=Panama
  [pe]=Peru [ph]=Philippines [pk]=Pakistan [pl]=Poland [pt]=Portugal
  [ro]=Romania [rs]=Serbia [ru]=Russia [sa]=Saudi-Arabia [sc]=Seychelles
  [se]=Sweden [sg]=Singapore [si]=Slovenia [sk]=Slovakia [th]=Thailand
  [tn]=Tunisia [tr]=Turkey [tw]=Taiwan [ua]=Ukraine [us]=United-States
  [uy]=Uruguay [vn]=Vietnam [za]=South-Africa
)
cc_label() { echo "${CC_NAME[$1]:-?}"; }

# ----------------------------------------------------------- node records ----
# A node is just its torrc: $NODES_DIR/<name>.torrc. Country and port are read
# back from it, so there is no second state file that can drift out of sync.

node_names() {
  local f
  shopt -s nullglob
  for f in "$NODES_DIR"/*.torrc; do f=${f##*/}; echo "${f%.torrc}"; done | sort -V
  shopt -u nullglob
}
node_cc()   { sed -n 's/^# country: //p' "$NODES_DIR/$1.torrc"; }
node_port() { sed -n 's/^SocksPort [^:]*:\([0-9]*\).*/\1/p' "$NODES_DIR/$1.torrc"; }
node_exists() { [[ -f $NODES_DIR/$1.torrc ]]; }

probe_host() {
  if [[ $BIND_ADDR == 0.0.0.0 ]]; then echo 127.0.0.1; else echo "$BIND_ADDR"; fi
}

used_ports() { local n; for n in $(node_names); do node_port "$n"; done; }

next_port() {
  local p=$BASE_PORT used
  used=" $(used_ports | tr '\n' ' ') "
  while [[ $used == *" $p "* ]] || ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; do
    ((p++))
  done
  echo "$p"
}

next_name() {  # de, de2, de3, ...
  local cc=$1 i=2
  node_exists "$cc" || { echo "$cc"; return; }
  while node_exists "$cc$i"; do ((i++)); done
  echo "$cc$i"
}

bridge_lines() { [[ -f $BRIDGES ]] && grep -Ev '^\s*(#|$)' "$BRIDGES" || true; }

render_torrc() {
  local name=$1 cc=$2 port=$3 ip line obfs
  {
    echo "# managed by tor-geo — regenerated on config changes, do not edit"
    echo "# country: $cc"
    echo "SocksPort $BIND_ADDR:$port"
    echo "SocksPolicy accept 127.0.0.0/8"
    [[ $BIND_ADDR != 0.0.0.0 && $BIND_ADDR != 127.* ]] && echo "SocksPolicy accept $BIND_ADDR"
    for ip in $ALLOW_IPS; do echo "SocksPolicy accept $ip"; done
    echo "SocksPolicy reject *"
    echo "DataDirectory $STATE_ROOT/$name"
    echo "ExitNodes {$cc}"
    echo "StrictNodes 1"
    echo "ClientOnly 1"
    echo "AvoidDiskWrites 1"
    echo "Log notice stdout"

    if [[ -n $(bridge_lines) ]]; then
      echo "UseBridges 1"
      obfs=$(command -v lyrebird || command -v obfs4proxy || true)
      [[ -n $obfs ]] && echo "ClientTransportPlugin obfs4 exec $obfs"
      command -v snowflake-client >/dev/null &&
        echo "ClientTransportPlugin snowflake exec $(command -v snowflake-client)"
      while IFS= read -r line; do
        line=${line#Bridge }
        echo "Bridge $line"
      done < <(bridge_lines)
    fi
  } > "$NODES_DIR/$name.torrc"
  chmod 644 "$NODES_DIR/$name.torrc"
}

# ---------------------------------------------------------------- probing ----

# Prints the exit IP seen through a node, or fails.
probe() {
  local port; port=$(node_port "$1")
  curl -fsS --max-time "$PROBE_TIMEOUT" --socks5-hostname "$(probe_host):$port" "$CHECK_URL" 2>/dev/null |
    grep -Eo '^[0-9a-fA-F:.]+$'
}

# Country of an IPv4 address according to Tor's own GeoIP database — the same
# data Tor uses for ExitNodes, so no external API and no rate limits.
geo_of() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  [[ $a$b$c$d =~ ^[0-9]+$ && -r $GEOIP ]] || return 0
  awk -F, -v n=$(( (a << 24) + (b << 16) + (c << 8) + d )) \
    '$1 !~ /^#/ && n >= $1 && n <= $2 { print tolower($3); exit }' "$GEOIP"
}
known_cc() { [[ ! -r $GEOIP ]] || grep -q ",${1^^}\$" "$GEOIP"; }

wait_ready() {  # wait_ready <name> [seconds] -> prints exit IP
  local name=$1 deadline=$((SECONDS + ${2:-120})) ip
  while ((SECONDS < deadline)); do
    if ip=$(probe "$name"); then echo "$ip"; return 0; fi
    sleep 5
  done
  return 1
}

boot_pct() {  # Tor bootstrap progress (0-100) of the node's current run
  local inv; inv=$(systemctl show -p InvocationID --value "tor-geo@$1")
  [[ -n $inv ]] || { echo 0; return; }
  journalctl _SYSTEMD_INVOCATION_ID="$inv" -o cat --no-pager 2>/dev/null |
    grep -o 'Bootstrapped [0-9]*' | tail -n 1 | grep -o '[0-9]*$' || echo 0
}

why_down() {  # short reason a node gives no exit IP
  local pct; pct=$(boot_pct "$1")
  if ((pct < 100)); then
    echo "still bootstrapping ($pct%) — slow link or Tor blocked (see: tor-geo bridges)"
  else
    echo "bootstrapped, but no working exit circuit — few exits in $(node_cc "$1")?"
  fi
}

since_active() {  # seconds since the unit last entered "active"
  local mono up
  mono=$(systemctl show "tor-geo@$1" -p ActiveEnterTimestampMonotonic --value)
  up=$(awk '{printf "%d", $1}' /proc/uptime)
  [[ ${mono:-0} -gt 0 ]] || { echo 0; return; }
  echo $(( up - mono / 1000000 ))
}

# ---------------------------------------------------------------- install ----

write_units() {
  cat > "$UNIT" <<EOF
[Unit]
Description=tor-geo exit instance %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TOR_USER
Group=$TOR_USER
StateDirectory=tor-geo/%i
StateDirectoryMode=0700
ExecStart=/usr/bin/tor -f $NODES_DIR/%i.torrc --RunAsDaemon 0
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=15
LimitNOFILE=65536
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "$HEAL_SVC" <<EOF
[Unit]
Description=tor-geo health check

[Service]
Type=oneshot
ExecStart=$BIN heal --quiet
EOF

  cat > "$HEAL_TIMER" <<EOF
[Unit]
Description=tor-geo health check every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
}

write_conf() {
  cat > "$CONF" <<EOF
# tor-geo settings. Run 'tor-geo regen' after editing by hand.
BIND_ADDR=$BIND_ADDR
ALLOW_IPS="$ALLOW_IPS"
BASE_PORT=$BASE_PORT
CHECK_URL=$CHECK_URL
PROBE_TIMEOUT=$PROBE_TIMEOUT
HEAL_FAILS=$HEAL_FAILS
BOOT_GRACE=$BOOT_GRACE
BOOT_LIMIT=$BOOT_LIMIT
EOF
}

cmd_install() {
  need_root
  command -v systemctl >/dev/null || die "systemd is required"
  command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"

  info "installing packages"
  local had_tor=0; command -v tor >/dev/null && had_tor=1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq tor tor-geoipdb curl jq ca-certificates iproute2 >/dev/null
  # The package starts its own Tor on 9050. Nobody uses it on a fresh install,
  # so stop it to save ~100 MB; leave it alone if Tor was already here.
  ((had_tor)) || systemctl disable --now tor.service >/dev/null 2>&1 || true
  # obfs4 transport for bridges; package name differs between releases
  apt-get install -y -qq lyrebird >/dev/null 2>&1 ||
    apt-get install -y -qq obfs4proxy >/dev/null 2>&1 ||
    warn "no obfs4 transport package found (only needed if you use bridges)"
  id "$TOR_USER" >/dev/null 2>&1 || die "user $TOR_USER missing — is the tor package installed?"

  local src; src=$(readlink -f "${BASH_SOURCE[0]}")
  if [[ -f $src ]]; then
    [[ $src == "$BIN" ]] || install -m 755 "$src" "$BIN"
  else  # started as: bash <(curl ...) — there is no file to copy
    curl -fsSL "$RAW_URL" -o "$BIN.new" && chmod 755 "$BIN.new" && mv "$BIN.new" "$BIN" ||
      die "could not download $RAW_URL"
  fi

  mkdir -p "$NODES_DIR" "$STATE_ROOT"
  [[ -f $CONF ]] || write_conf
  [[ -f $BRIDGES ]] || cat > "$BRIDGES" <<'EOF'
# One bridge per line, as given by https://bridges.torproject.org or @GetBridgesBot.
# Only needed when the server itself cannot reach Tor (e.g. a server inside Iran).
# Example:
# obfs4 1.2.3.4:443 FINGERPRINT cert=... iat-mode=0
EOF

  write_units
  systemctl daemon-reload
  systemctl enable --now tor-geo-heal.timer >/dev/null 2>&1
  ok "installed $BIN v$VERSION"
  echo "   next: tor-geo countries   (see which countries have exits)"
  echo "         tor-geo add de nl us"
}

cmd_update() {
  need_root
  local tmp; tmp=$(mktemp)
  curl -fsSL "$RAW_URL" -o "$tmp" || die "could not download $RAW_URL"
  bash -n "$tmp" || die "downloaded script has syntax errors, keeping the current one"
  install -m 755 "$tmp" "$BIN"; rm -f "$tmp"
  "$BIN" install >/dev/null && ok "updated to v$("$BIN" version)"
  echo "   run 'tor-geo regen' if the release notes mention torrc changes"
}

cmd_uninstall() {
  need_root
  local n a
  read -rp "Remove all tor-geo nodes, config and units? [y/N] " a
  [[ $a == [yY] ]] || { echo "aborted"; return; }
  for n in $(node_names); do systemctl disable --now "tor-geo@$n" >/dev/null 2>&1 || true; done
  systemctl disable --now tor-geo-heal.timer >/dev/null 2>&1 || true
  rm -f "$UNIT" "$HEAL_SVC" "$HEAL_TIMER"
  systemctl daemon-reload
  rm -rf "$CONF_DIR" "$STATE_ROOT" "$RUN_DIR"
  rm -f "$BIN"
  ok "removed (the tor package itself is left installed: apt purge tor)"
}

# ------------------------------------------------------------------ nodes ----

# Bootstrapping means downloading ~10k relay descriptors, which on some links
# takes minutes. Every node needs the same data, so a new node starts from a
# copy of an existing node's directory cache and only fetches what changed.
SEED_FILES=(cached-certs cached-microdesc-consensus cached-microdescs cached-microdescs.new)

seed_source() {  # node with the freshest usable directory cache, or nothing
  local n f t newest=0 best=""
  for n in $(node_names); do
    f=$STATE_ROOT/$n/cached-microdesc-consensus
    [[ -s $f && -s $STATE_ROOT/$n/cached-certs ]] || continue
    t=$(stat -c %Y "$f")
    if ((t > newest)); then newest=$t; best=$n; fi
  done
  echo "$best"
}

seed_dir() {  # seed_dir <new-name> -> prints the node it copied from, if any
  local dst=$STATE_ROOT/$1 src f
  src=$(seed_source)
  [[ -n $src && $src != "$1" ]] || return 0
  mkdir -p "$dst"
  for f in "${SEED_FILES[@]}"; do
    if [[ -f $STATE_ROOT/$src/$f ]]; then cp "$STATE_ROOT/$src/$f" "$dst/"; fi
  done
  chown -R "$TOR_USER:$TOR_USER" "$dst"
  chmod 700 "$dst"
  echo "$src"
}

wait_boot() {  # wait_boot <name> <seconds>: until Tor reports 100%
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    (($(boot_pct "$1") >= 100)) && return 0
    sleep 5
  done
  return 1
}

add_one() {  # add_one <cc> -> prints "<name> <seed-source>"
  local cc=$1 name port src
  name=$(next_name "$cc")
  port=$(next_port)
  render_torrc "$name" "$cc" "$port"
  src=$(seed_dir "$name")
  if ! systemctl enable --now "tor-geo@$name" >/dev/null 2>&1; then
    rm -f "$NODES_DIR/$name.torrc"
    die "tor-geo@$name failed to start: journalctl -u tor-geo@$name"
  fi
  echo "$name $src"
}

start_node() {  # start_node <cc>: add_one + report; appends to $added
  local name src
  read -r name src <<<"$(add_one "$1")"
  [[ -n $name ]] || exit 1
  added+=("$name")
  ok "$name  ($(cc_label "$1"))  socks5://$(probe_host):$(node_port "$name")${src:+  ${C_D}[cache from $src]${C_0}}"
}

cmd_add() {
  need_root; need_installed
  local force=0 arg cc count exits i name counts added=() picked=() todo=()
  if [[ ${1:-} == --force ]]; then force=1; shift; fi
  [[ $# -gt 0 ]] || die "usage: tor-geo add [--force] <cc>[:count] ...   e.g. tor-geo add de nl:2 us
       tor-geo add --top 10"

  counts=$(exit_counts 2>/dev/null || true)   # empty if onionoo is unreachable
  if [[ $1 == --top ]]; then
    [[ -n $counts ]] || die "--top needs onionoo.torproject.org, which is unreachable"
    mapfile -t picked < <(awk '$2 != "??" {print $2}' <<<"$counts" | head -n "${2:-10}")
    set -- "${picked[@]}"
  fi

  for arg in "$@"; do
    cc=${arg%%:*}; cc=${cc,,}
    count=1; [[ $arg == *:* ]] && count=${arg##*:}
    [[ $cc =~ ^[a-z]{2}$ ]] && known_cc "$cc" ||
      die "unknown country code: $arg (use ISO codes: de, nl, us ...)"
    [[ $count =~ ^[0-9]+$ && $count -ge 1 ]] || die "bad count in: $arg"
    if [[ -n $counts ]]; then
      exits=$(awk -v c="$cc" '$2 == c {print $1}' <<<"$counts")
      if [[ -z $exits ]] && ((!force)); then
        warn "skipping $cc ($(cc_label "$cc")): no running Tor exits there right now (override: add --force $cc)"
        continue
      fi
      ((${exits:-0} < 5)) && warn "$cc has only ${exits:-0} exit relay(s): expect slow and repeated IPs"
    fi
    for ((i = 0; i < count; i++)); do todo+=("$cc"); done
  done
  ((${#todo[@]})) || return 0

  # Nothing to copy a directory cache from yet: bootstrap one node first so
  # the others don't each download the whole directory in parallel.
  if [[ -z $(seed_source) && ${#todo[@]} -gt 1 ]]; then
    start_node "${todo[0]}"
    info "${added[0]} downloads the Tor directory once, the other nodes will copy it"
    wait_boot "${added[0]}" "$BOOT_LIMIT" ||
      warn "${added[0]} did not finish bootstrapping; starting the rest without a cache"
    todo=("${todo[@]:1}")
  fi
  for cc in "${todo[@]}"; do start_node "$cc"; done

  info "waiting for ${#added[@]} node(s) to get a working exit"
  local dir; dir=$(mktemp -d)
  for name in "${added[@]}"; do
    ( wait_ready "$name" 200 > "$dir/$name" || true ) &
  done
  wait
  for name in "${added[@]}"; do
    local ip; ip=$(<"$dir/$name")
    if [[ -n $ip ]]; then
      ok "$name ready — exit IP $ip"
    else
      warn "$name not ready: $(why_down "$name"). Re-test later: tor-geo check"
    fi
  done
  rm -rf "$dir"
}

resolve_targets() {  # name|cc|all -> node names
  local t=$1 n found=0
  if [[ $t == all ]]; then node_names; return; fi
  if node_exists "$t"; then echo "$t"; return; fi
  for n in $(node_names); do
    [[ $(node_cc "$n") == "$t" ]] && { echo "$n"; found=1; }
  done
  ((found)) || die "no node or country named '$t' (see: tor-geo list)"
}

cmd_remove() {
  need_root; need_installed
  [[ $# -gt 0 ]] || die "usage: tor-geo remove <name|cc|all> ..."
  local t n
  for t in "$@"; do
    for n in $(resolve_targets "$t"); do
      systemctl disable --now "tor-geo@$n" >/dev/null 2>&1 || true
      rm -f "$NODES_DIR/$n.torrc" "$RUN_DIR/$n".*
      rm -rf "${STATE_ROOT:?}/$n"
      ok "removed $n"
    done
  done
}

cmd_rotate() {
  need_root; need_installed
  local t n
  for t in "${@:-all}"; do
    for n in $(resolve_targets "$t"); do
      rm -f "$RUN_DIR/$n".*
      systemctl restart "tor-geo@$n" && ok "restarted $n (new circuits, likely new IP)"
    done
  done
}

cmd_list() {
  need_installed
  local n cc st col ip names
  names=$(node_names)
  [[ -n $names ]] || { echo "no nodes yet — try: tor-geo add de nl us"; return; }
  printf '%-8s %-3s %-16s %-6s %-12s %s\n' NAME CC COUNTRY PORT STATE "LAST EXIT IP"
  for n in $names; do
    cc=$(node_cc "$n")
    st=$(systemctl is-active "tor-geo@$n" 2>/dev/null || true)
    if [[ $st == active ]]; then col=$C_G; else col=$C_R; fi
    ip=$(cat "$RUN_DIR/$n.ip" 2>/dev/null || echo "-")
    printf '%-8s %-3s %-16s %-6s %s%-12s%s %s\n' "$n" "$cc" "$(cc_label "$cc")" "$(node_port "$n")" \
      "$col" "${st:-?}" "$C_0" "$ip"
  done
  echo
  echo "${C_D}bind: $BIND_ADDR   allowed: ${ALLOW_IPS:-local only}   live check: tor-geo check${C_0}"
}

cmd_check() {  # live probe of every node, in parallel
  need_installed
  local names n dir; names=$(node_names)
  [[ -n $names ]] || { echo "no nodes"; return; }
  dir=$(mktemp -d)
  info "probing $(wc -w <<<"$names") node(s) through Tor (≤${PROBE_TIMEOUT}s)"
  for n in $names; do
    (
      local t0 ip geo
      t0=$(date +%s%N)
      if ip=$(probe "$n"); then
        geo=$(geo_of "$ip" || true)
        echo "ok $ip ${geo:-?} $(( ($(date +%s%N) - t0) / 1000000 ))" > "$dir/$n"
        { mkdir -p "$RUN_DIR" && echo "$ip" > "$RUN_DIR/$n.ip"; } 2>/dev/null || true
      fi
    ) &
  done
  wait
  printf '%-8s %-3s %-6s %-6s %-40s %-4s %s\n' NAME CC PORT RESULT "EXIT IP" GEO LATENCY
  local r ip geo ms cc mark
  for n in $names; do
    r=fail ip="" geo="" ms=""
    [[ -s $dir/$n ]] && read -r r ip geo ms < "$dir/$n"
    cc=$(node_cc "$n")
    if [[ $r == ok ]]; then
      mark=""; [[ $geo != "$cc" && $geo != "?" ]] && mark=" ${C_Y}(exit is not in $cc!)${C_0}"
      printf '%-8s %-3s %-6s %s %-40s %-4s %sms%s\n' "$n" "$cc" "$(node_port "$n")" "${C_G}ok    ${C_0}" "$ip" "$geo" "$ms" "$mark"
    else
      printf '%-8s %-3s %-6s %s\n' "$n" "$cc" "$(node_port "$n")" "${C_R}FAIL${C_0}   $(why_down "$n")"
    fi
  done
  rm -rf "$dir"
}

# Called by tor-geo-heal.timer. Restarts dead or unresponsive nodes.
cmd_heal() {
  need_root; need_installed
  local quiet=0; [[ ${1:-} == --quiet ]] && quiet=1
  local n
  mkdir -p "$RUN_DIR"
  for n in $(node_names); do
    (
      local fails ip pct up
      if ! systemctl is-active --quiet "tor-geo@$n"; then
        logger -t tor-geo "$n inactive, starting"
        systemctl start "tor-geo@$n" || true
        exit
      fi
      up=$(since_active "$n")
      ((up < BOOT_GRACE)) && exit
      if ip=$(probe "$n"); then
        echo "$ip" > "$RUN_DIR/$n.ip"
        rm -f "$RUN_DIR/$n.fails"
        ((quiet)) || ok "$n $ip"
      else
        # A restart mid-bootstrap only throws the progress away. Give a slow
        # first download BOOT_LIMIT seconds before treating the node as stuck.
        pct=$(boot_pct "$n")
        if ((pct < 100 && up < BOOT_LIMIT)); then
          ((quiet)) || info "$n still bootstrapping ($pct%)"
          exit
        fi
        fails=$(( $(cat "$RUN_DIR/$n.fails" 2>/dev/null || echo 0) + 1 ))
        if ((fails >= HEAL_FAILS)); then
          logger -t tor-geo "$n failed $fails probes, restarting"
          ((quiet)) || warn "$n failed $fails probes, restarting"
          rm -f "$RUN_DIR/$n.fails" "$RUN_DIR/$n.ip"
          systemctl restart "tor-geo@$n" || true
        else
          echo "$fails" > "$RUN_DIR/$n.fails"
          ((quiet)) || warn "$n probe failed ($fails/$HEAL_FAILS)"
        fi
      fi
    ) &
  done
  wait
}

cmd_logs() {
  [[ $# -gt 0 ]] || die "usage: tor-geo logs <name>"
  node_exists "$1" || die "no node named $1"
  journalctl -u "tor-geo@$1" -n 60 --no-pager -o short-iso
}

# --------------------------------------------------------------- settings ----

regen_all() {  # rewrite every torrc from current settings and restart
  local n
  for n in $(node_names); do
    render_torrc "$n" "$(node_cc "$n")" "$(node_port "$n")"
    systemctl restart "tor-geo@$n" || warn "restart of $n failed"
  done
}

cmd_regen() { need_root; need_installed; regen_all; ok "regenerated $(node_names | wc -l) node(s)"; }

cmd_expose() {
  need_root; need_installed
  [[ $# -gt 0 ]] || die "usage: tor-geo expose <your-ip|cidr> ...
   Opens the SOCKS ports on all interfaces, but only for these addresses.
   Without an allow-list this would be an open proxy, so it is refused."
  local ip
  for ip in "$@"; do
    [[ $ip =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]] || die "not an IP/CIDR: $ip"
    [[ $ip == 0.0.0.0/0 || $ip == ::/0 ]] && die "refusing to allow the whole internet"
  done
  BIND_ADDR=0.0.0.0
  ALLOW_IPS="$*"
  write_conf
  regen_all
  ok "ports open on 0.0.0.0, accepted only from: $ALLOW_IPS"
  echo "   also allow the port range in your firewall / cloud security group"
}

cmd_unexpose() {
  need_root; need_installed
  BIND_ADDR=127.0.0.1; ALLOW_IPS=""
  write_conf; regen_all
  ok "ports are local only again (127.0.0.1)"
}

cmd_bridges() {
  need_root; need_installed
  case ${1:-edit} in
    edit)  "${EDITOR:-nano}" "$BRIDGES" ;;
    clear) sed -i '/^\s*[^#[:space:]]/d' "$BRIDGES" ;;
    show)  bridge_lines; return ;;
    *)     die "usage: tor-geo bridges [edit|show|clear]" ;;
  esac
  local count; count=$(bridge_lines | wc -l)
  if ((count > 0)) && ! command -v lyrebird >/dev/null && ! command -v obfs4proxy >/dev/null; then
    warn "bridges set but no obfs4 transport installed: apt install lyrebird (or obfs4proxy)"
  fi
  regen_all
  ok "$count bridge(s) active on all nodes"
}

# ----------------------------------------------------------------- export ----

# "<count> <cc>" for countries with running exits, most first. Reads the
# consensus a node already downloaded (works where torproject.org is blocked,
# and is exactly what Tor itself sees); falls back to onionoo before the first
# node exists.
exit_counts() {
  exit_counts_local || exit_counts_onionoo
}

exit_counts_local() {
  local src out
  src=$(seed_source)
  [[ -n $src && -r $GEOIP ]] || return 1
  # Load GeoIP ranges, then binary-search the IP of every relay flagged Exit.
  out=$(awk '
    FNR == NR { if ($0 !~ /^#/) { split($0, a, ","); lo[n] = a[1] + 0; hi[n] = a[2] + 0; cc[n] = tolower(a[3]); n++ }; next }
    /^r / { ip = $6; next }
    /^s / && / Exit/ && !/BadExit/ {
      split(ip, o, "."); v = o[1] * 16777216 + o[2] * 65536 + o[3] * 256 + o[4]
      l = 0; h = n - 1; c = "??"
      while (l <= h) { m = int((l + h) / 2); if (v < lo[m]) h = m - 1; else if (v > hi[m]) l = m + 1; else { c = cc[m]; break } }
      count[c]++
    }
    END { for (c in count) print count[c], c }
  ' "$GEOIP" "$STATE_ROOT/$src/cached-microdesc-consensus" | sort -rn)
  [[ -n $out ]] && echo "$out"
}

exit_counts_onionoo() {
  curl -fsS --max-time 20 \
    'https://onionoo.torproject.org/details?type=relay&running=true&flag=Exit&fields=country' |
    jq -r '.relays | map(.country // "??") | group_by(.) | map("\(length) \(.[0])") | .[]' |
    sort -rn
}

cmd_countries() {
  local data
  data=$(exit_counts) || die "no node has a Tor directory yet and onionoo.torproject.org is unreachable.
       Add a node first (tor-geo add de); if Tor itself is blocked here, set bridges (tor-geo bridges)."
  printf '%-4s %-18s %s\n' CC COUNTRY EXITS
  local n cc
  while read -r n cc; do
    printf '%-4s %-18s %s\n' "$cc" "$(cc_label "$cc")" "$n"
  done <<<"$data"
  echo
  echo "${C_D}fewer than ~5 exits = slow, unstable, often the same IP${C_0}"
}

cmd_export() {  # plain list of proxy URLs
  need_installed
  local n host
  host=$(probe_host)
  [[ $BIND_ADDR == 0.0.0.0 ]] && host=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  for n in $(node_names); do
    echo "socks5://$host:$(node_port "$n")#$n-$(cc_label "$(node_cc "$n")")"
  done
}

cmd_xray() {  # Xray outbounds + routing rules, one per node
  need_installed
  local prefix=${1:-in-} n arr=()
  for n in $(node_names); do arr+=("$n:$(node_port "$n")"); done
  [[ ${#arr[@]} -gt 0 ]] || die "no nodes"
  printf '%s\n' "${arr[@]}" | jq -R -s --arg prefix "$prefix" --arg host "$(probe_host)" '
    split("\n") | map(select(length > 0) | split(":") | {name: .[0], port: (.[1] | tonumber)}) |
    {
      outbounds: map({
        tag: "tor-\(.name)",
        protocol: "socks",
        settings: {servers: [{address: $host, port: .port}]}
      }),
      routing: {rules: map({
        type: "field",
        inboundTag: ["\($prefix)\(.name)"],
        outboundTag: "tor-\(.name)"
      })}
    }'
  echo "# Merge 'outbounds' and 'routing.rules' into your Xray core config. Create one" >&2
  echo "# inbound per node tagged ${prefix}<name> (e.g. ${prefix}de). UDP is not carried by Tor." >&2
}

# ------------------------------------------------------------------- menu ----

run() { ( "$@" ) || true; }

cmd_menu() {
  need_root
  local c args
  while true; do
    # shellcheck source=/dev/null
    [[ -f $CONF ]] && source "$CONF"
    echo
    echo "${C_B}tor-geo v$VERSION${C_0}   nodes: $( [[ -d $NODES_DIR ]] && node_names | wc -l || echo 0)   bind: $BIND_ADDR"
    cat <<EOF
  1) install / repair            7) live check (IP + geo)
  2) list countries with exits   8) rotate IPs
  3) add nodes                   9) Xray outbounds JSON
  4) add top-N countries        10) expose to my IP
  5) list nodes                 11) bridges (server can't reach Tor)
  6) remove nodes               12) uninstall
  0) exit
EOF
    read -rp "choice: " c || return
    case $c in
      1) run cmd_install ;;
      2) run cmd_countries ;;
      3) read -rp "country codes (e.g. de nl:2 us): " args; run cmd_add $args ;;
      4) read -rp "how many countries? [10]: " args; run cmd_add --top "${args:-10}" ;;
      5) run cmd_list ;;
      6) read -rp "names, country codes, or 'all': " args; run cmd_remove $args ;;
      7) run cmd_check ;;
      8) read -rp "names, country codes, or 'all' [all]: " args; run cmd_rotate ${args:-all} ;;
      9) run cmd_xray ;;
      10) read -rp "your IP(s)/CIDR(s): " args; run cmd_expose $args ;;
      11) run cmd_bridges edit ;;
      12) run cmd_uninstall; [[ -f $UNIT ]] || return 0 ;;
      0|q) return ;;
      *) echo "?" ;;
    esac
  done
}

usage() {
  cat <<EOF
tor-geo v$VERSION — one Tor instance per exit country, each on its own SOCKS5 port

  install                    install packages, systemd units, /usr/local/bin/tor-geo
  countries                  countries that currently have Tor exit relays
  add [--force] <cc>[:n] ... add nodes, e.g.  add de nl:2 us
  add --top <N>              add the N countries with the most exits
  list                       nodes, ports, state, last seen exit IP
  check                      probe every node now (exit IP, geo, latency)
  rotate [name|cc|all]       restart nodes to get new circuits
  remove <name|cc|all> ...   delete nodes
  logs <name>                recent Tor log of one node
  export                     socks5:// URLs of all nodes
  xray [inbound-prefix]      Xray outbounds + routing JSON (default prefix: in-)
  expose <ip|cidr> ...       listen on 0.0.0.0, accept only these clients
  unexpose                   back to 127.0.0.1 only
  bridges [edit|show|clear]  use Tor bridges (for servers that can't reach Tor)
  regen                      rewrite all torrc files from settings and restart
  heal                       health check (runs every 5 min via systemd timer)
  update                     download the latest tor-geo from GitHub
  uninstall                 remove everything tor-geo created
  (no argument)              interactive menu
EOF
}

main() {
  local cmd=${1:-menu}; shift || true
  case $cmd in
    install)   cmd_install ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    countries) cmd_countries ;;
    add)       cmd_add "$@" ;;
    remove|rm|del) cmd_remove "$@" ;;
    list|ls)   cmd_list ;;
    check)     cmd_check ;;
    rotate)    cmd_rotate "$@" ;;
    heal)      cmd_heal "$@" ;;
    logs)      cmd_logs "$@" ;;
    export)    cmd_export ;;
    xray)      cmd_xray "$@" ;;
    expose)    cmd_expose "$@" ;;
    unexpose)  cmd_unexpose ;;
    bridges)   cmd_bridges "$@" ;;
    regen)     cmd_regen ;;
    menu)      cmd_menu ;;
    version|-v|--version) echo "$VERSION" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
