#!/system/bin/sh
# Mishka 系统 IPv6 对账脚本（移植自 mihomo_box 的 system_ipv6_sync / apn4 逻辑）
# 用法：
#   sh system_ipv6.sh once  <0|1> <状态目录>   一次性对账（1=恢复，0=禁用）
#   sh system_ipv6.sh watch 0     <状态目录>   常驻对账循环（关态，每 5 秒一拍）
#   sh system_ipv6.sh status 0    <状态目录>   输出首选 APN：id|apn|protocol|roaming|type
#   sh system_ipv6.sh stop  0     <状态目录>   停掉常驻循环

ACTION=${1:-once}
WANT=${2:-0}
STATE=${3:-/data/local/tmp/mishka_ipv6}

mkdir -p "$STATE" 2>/dev/null
LOG="$STATE/log"
PID_FILE="$STATE/watch.pid"
WANT_FILE="$STATE/ipv6.want"
NET_FILE="$STATE/ipv6.net"
LAST_FILE="$STATE/ipv6.last"
APN_STATE="$STATE/apn.state"
APN_CACHE="$STATE/apn.current"
IPV6_CONF="/proc/sys/net/ipv6/conf"
IPV6_COOL=60
IP="/system/bin/ip"
[ -x "$IP" ] || IP="ip"

if [ "$WANT" = "1" ]; then DIS=0; else DIS=1; fi

log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOG" 2>/dev/null
}

setv() {
  [ -e "$1" ] || return 0
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" > "$1" 2>/dev/null
}

# 蜂窝数据口：协议栈靠 APN 切纯 IPv4，不动内核 disable_ipv6（免得断数据 / 掉 IMS）
is_cellular_if() {
  case "$1" in rmnet*|ccmni*|wwan*|r_rmnet*) return 0 ;; esac
  return 1
}

# 单次拉取热点网段关联的接口列表，避免在循环中对每块网卡重复 fork ip/grep
_TETHER_IFACES=""
refresh_tether_ifaces() {
  _TETHER_IFACES=$($IP -4 -o addr show 2>/dev/null | awk '
    /inet (192\.168\.(42|43|49|225)\.|172\.20\.10\.)/ { print $2 }
  ')
}

# 热点下游口（Wi-Fi AP / USB 共享 / 蓝牙共享）：交还系统，保留下游设备 IPv6 能力
is_tether_if() {
  case "$1" in
    ap*|softap*|wlan*ap*|swlan*|rndis*|usb*|ncm*|bt-pan*|bnep*) return 0 ;;
    wlan*|eth*)
      case " $_TETHER_IFACES " in
        *" $1 "*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

is_exempt_if() {
  [ "$1" = "lo" ] && return 0
  is_cellular_if "$1" && return 0
  is_tether_if "$1" && return 0
  return 1
}

fingerprint() {
  for _p in /sys/class/net/*/operstate; do
    [ -e "$_p" ] || continue
    _i=${_p%/operstate}; _i=${_i##*/}
    [ "$_i" = "lo" ] && continue
    printf '%s=%s;' "$_i" "$(cat "$_p" 2>/dev/null)"
  done
}

# ---------------- APN 协议（上网 APN → IP，IMS 不动） ----------------

parse_apn_out() {
  awk '
    /^Row:/ {
      id=""; apn=""; p=""; r=""; t=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^_id=/)              { sub(/^_id=/, "", $i); id=$i }
        else if ($i ~ /^apn=/)         { sub(/^apn=/, "", $i); apn=$i }
        else if ($i ~ /^protocol=/)    { sub(/^protocol=/, "", $i); p=$i }
        else if ($i ~ /^roaming_protocol=/) { sub(/^roaming_protocol=/, "", $i); r=$i }
        else if ($i ~ /^type=/)        { sub(/^type=/, "", $i); t=$i }
      }
      if (id != "" && id != "NULL" && !seen[id]++) print id "|" apn "|" p "|" r "|" t
    }
  '
}

apn_rows() {
  _proj="_id:apn:protocol:roaming_protocol:type"
  # 优先查默认主卡 preferapn（仅启动 1 个 app_process），为空时才回退查双卡 subId/1..2
  _out=$(content query --uri content://telephony/carriers/preferapn --projection "$_proj" 2>/dev/null | parse_apn_out)
  if [ -z "$_out" ]; then
    _d="$STATE/apnq.$$"
    mkdir -p "$_d" 2>/dev/null || return 0
    for _n in 1 2; do
      content query --uri "content://telephony/carriers/preferapn/subId/$_n" --projection "$_proj" > "$_d/$_n" 2>/dev/null &
    done
    wait
    _out=$(cat "$_d"/* 2>/dev/null | parse_apn_out)
    rm -rf "$_d" 2>/dev/null
  fi
  if [ -n "$_out" ]; then
    printf '%s\n' "$_out" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
    printf '%s\n' "$_out"
  fi
}

# 翻转开关瞬间先乐观更新缓存文件，保证 UI 读取 0 等待
apn_optimistic_cache() {
  [ -s "$APN_CACHE" ] || return 0
  if [ "$WANT" = "0" ]; then
    while IFS='|' read -r _id _apn _p _r _t; do
      [ -z "$_id" ] && continue
      case ",$_t," in *,[iI][mM][sS],*) continue ;; esac
      if [ "$_p" != "IP" ] || [ "$_r" != "IP" ]; then
        if ! grep -q "^$_id|" "$APN_STATE" 2>/dev/null; then
          printf '%s|%s|%s|%s\n' "$_id" "$_apn" "$_p" "$_r" >> "$APN_STATE"
          chmod 0644 "$APN_STATE" 2>/dev/null
        fi
      fi
    done < "$APN_CACHE"
    awk -F'|' 'BEGIN{OFS="|"} {
      t="," tolower($5) ","
      if (index(t, ",ims,") == 0) { $3="IP"; $4="IP" }
      print
    }' "$APN_CACHE" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
  else
    [ -f "$APN_STATE" ] || return 0
    awk -F'|' 'BEGIN{OFS="|"}
      NR==FNR { orig_p[$1]=$3; orig_r[$1]=$4; next }
      {
        if ($1 in orig_p) { $3=orig_p[$1]; $4=orig_r[$1] }
        print
      }
    ' "$APN_STATE" "$APN_CACHE" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
  fi
}

apn_reattach() {
  command -v svc >/dev/null 2>&1 || { log "WARN 无 svc，请手动开关一次飞行模式使 APN 协议生效"; return 0; }
  log "重新附着数据（svc data off/on）"
  ( svc data disable >/dev/null 2>&1; sleep 2; svc data enable >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
  return 0
}

apn_apply() {
  command -v content >/dev/null 2>&1 || return 0
  _rows=$(apn_rows)
  [ -z "$_rows" ] && return 0
  _changed=0
  while IFS='|' read -r _id _apn _p _r _t; do
    [ -z "$_id" ] && continue
    case ",$_t," in *,[iI][mM][sS],*) continue ;; esac
    if [ "$_p" = "IP" ] && [ "$_r" = "IP" ]; then continue; fi
    if ! grep -q "^$_id|" "$APN_STATE" 2>/dev/null; then
      printf '%s|%s|%s|%s\n' "$_id" "$_apn" "$_p" "$_r" >> "$APN_STATE"
      chmod 0644 "$APN_STATE" 2>/dev/null
    fi
    if content update --uri content://telephony/carriers --where "_id=$_id" \
         --bind protocol:s:IP --bind roaming_protocol:s:IP >/dev/null 2>&1; then
      log "APN 改为 IPv4：$_apn (id=$_id) $_p/$_r -> IP/IP"
      _changed=1
    else
      log "WARN APN 写入未生效：$_apn (id=$_id)"
    fi
  done <<EOF
$_rows
EOF
  if [ "$_changed" = "1" ]; then
    apn_optimistic_cache
    apn_reattach
  fi
  return 0
}

apn_restore() {
  [ -f "$APN_STATE" ] || return 0
  command -v content >/dev/null 2>&1 || return 0
  _changed=0; _fail=0
  while IFS='|' read -r _id _apn _p _r; do
    [ -z "$_id" ] && continue
    [ -z "$_p" ] && _p="IPV4V6"
    [ -z "$_r" ] && _r="IP"
    if content update --uri content://telephony/carriers --where "_id=$_id" \
         --bind "protocol:s:$_p" --bind "roaming_protocol:s:$_r" >/dev/null 2>&1; then
      log "APN 已还原：$_apn (id=$_id) -> $_p/$_r"
      _changed=1
    else
      log "WARN APN 还原未生效：$_apn (id=$_id)"
      _fail=1
    fi
  done < "$APN_STATE"
  if [ "$_changed" = "1" ]; then
    apn_optimistic_cache
  fi
  [ "$_fail" = "0" ] && rm -f "$APN_STATE" 2>/dev/null
  [ "$_changed" = "1" ] && apn_reattach
  return 0
}

# ---------------- 非蜂窝网卡 sysctl 对账 ----------------

sync_once() {
  [ -d "$IPV6_CONF" ] || return 0
  refresh_tether_ifaces

  # 热点下游若被旧版写成 disable_ipv6=1，交还系统
  for _f in "$IPV6_CONF"/*/disable_ipv6; do
    [ -e "$_f" ] || continue
    _i=${_f%/disable_ipv6}; _i=${_i##*/}
    is_tether_if "$_i" || continue
    setv "$_f" 0
  done

  _prev=$(cat "$WANT_FILE" 2>/dev/null)
  _cur=$(fingerprint)
  _netprev=$(cat "$NET_FILE" 2>/dev/null)
  _need=0; _flip=0; _netchg=0; _drift=0
  if [ "$_prev" != "$WANT" ]; then
    _need=1; _flip=1
  elif [ "$WANT" = "1" ]; then
    # 开态：只更新指纹，不写任何东西
    [ "$_cur" = "$_netprev" ] || printf '%s' "$_cur" > "$NET_FILE"
    return 0
  else
    # 关态：切网 → 必修；网络未变 → 扫描是否有网卡被放回 0，有则按 60 秒冷却追打
    if [ "$_cur" != "$_netprev" ] || [ -z "$_netprev" ]; then
      _need=1; _netchg=1
    else
      for _f in "$IPV6_CONF"/*/disable_ipv6; do
        [ -e "$_f" ] || continue
        _i=${_f%/disable_ipv6}; _i=${_i##*/}
        is_exempt_if "$_i" && continue
        if [ "$(cat "$_f" 2>/dev/null)" != "$DIS" ]; then _need=1; _drift=1; break; fi
      done
      if [ "$_need" = "1" ]; then
        _now=$(date +%s 2>/dev/null); _last=$(cat "$LAST_FILE" 2>/dev/null)
        case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
        case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
        if [ "$_now" -gt 0 ] && [ "$_last" -gt 0 ] && [ $((_now - _last)) -lt "$IPV6_COOL" ]; then
          _need=0
        fi
      fi
    fi
  fi
  [ "$_need" = "1" ] || return 0

  # 第一步（毫秒级同步完成）：立即改写非蜂窝、非豁免网卡 sysctl 并落盘状态
  _n=0; _changed=""
  for _f in "$IPV6_CONF"/*/disable_ipv6; do
    [ -e "$_f" ] || continue
    _i=${_f%/disable_ipv6}; _i=${_i##*/}
    is_exempt_if "$_i" && continue
    [ "$(cat "$_f" 2>/dev/null)" = "$DIS" ] && continue
    if echo "$DIS" > "$_f" 2>/dev/null; then
      _n=$((_n + 1)); _changed="$_changed $_i"
      if [ "$WANT" = "0" ]; then
        setv "$IPV6_CONF/$_i/accept_ra" 0
        setv "$IPV6_CONF/$_i/autoconf" 0
        setv "$IPV6_CONF/$_i/accept_ra_defrtr" 0
        setv "$IPV6_CONF/$_i/accept_ra_pinfo" 0
      else
        setv "$IPV6_CONF/$_i/accept_ra" 2
        setv "$IPV6_CONF/$_i/autoconf" 1
        setv "$IPV6_CONF/$_i/accept_ra_defrtr" 1
        setv "$IPV6_CONF/$_i/accept_ra_pinfo" 1
        setv "$IPV6_CONF/$_i/accept_ra_rtr_pref" 1
        setv "$IPV6_CONF/$_i/disable_tempaddr" 0
        setv "$IPV6_CONF/$_i/router_solicitations" 3
      fi
    fi
  done

  printf '%s' "$WANT" > "$WANT_FILE"
  printf '%s' "$_cur" > "$NET_FILE"
  if [ "$_drift" = "1" ]; then
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) ;; *) printf '%s' "$_now" > "$LAST_FILE" ;; esac
  fi
  if [ "$_n" -gt 0 ]; then
    if [ "$WANT" = "1" ]; then _w=开; else _w=关; fi
    log "系统 IPv6 对账（$_w）：应用 $_n 块网卡"
  fi

  if [ "$_flip" = "1" ]; then
    apn_optimistic_cache
  fi

  # 第二步（耗时操作：content 改写 APN + ndc 通知 netd）：
  # once 模式下放后台异步执行，避免阻塞 UI 开关切换数秒；watch 循环中顺序执行即可
  _do_slow_work() {
    if [ "$WANT" = "0" ]; then
      if [ "$_flip" = "1" ] || [ "$_netchg" = "1" ]; then apn_apply; fi
    else
      if [ "$_flip" = "1" ]; then apn_restore; fi
    fi

    if [ "$WANT" = "1" ] && [ -n "$_changed" ]; then
      if command -v ndc >/dev/null 2>&1; then
        for _i in $_changed; do
          case "$_i" in wlan*|eth*|ap*|p2p*) ndc interface ipv6 "$_i" enable >/dev/null 2>&1 ;; esac
        done
      fi
    fi
  }

  if [ "$ACTION" = "once" ]; then
    ( _do_slow_work ) </dev/null >>"$LOG" 2>&1 &
  else
    _do_slow_work
  fi
  return 0
}

kill_loop() {
  _old=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$_old" ] && [ "$_old" != "$$" ]; then kill "$_old" 2>/dev/null; fi
  rm -f "$PID_FILE" 2>/dev/null
  return 0
}

case "$ACTION" in
  once)
    kill_loop
    sync_once
    ;;
  watch)
    kill_loop
    echo "$$" > "$PID_FILE"
    log "常驻对账启动（pid=$$，want=$WANT）"
    while :; do
      [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] || exit 0
      sync_once
      sleep 5
    done
    ;;
  status)
    if [ -s "$APN_CACHE" ]; then
      cat "$APN_CACHE"
      ( apn_rows >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
    else
      apn_rows
    fi
    ;;
  stop)
    kill_loop
    ;;
esac
exit 0
