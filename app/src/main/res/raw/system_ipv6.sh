#!/system/bin/sh
# Mishka 系统 IPv6 对账脚本（移植自 mihomo_box 的 system_ipv6_sync / apn4 逻辑）
# 由应用复制到私有目录，经 root 执行。用法：
#   sh system_ipv6.sh once  <0|1> <状态目录>   一次性对账（1=恢复，0=禁用）
#   sh system_ipv6.sh watch 0     <状态目录>   常驻对账循环（关态，每 5 秒一拍）
#   sh system_ipv6.sh status 0    <状态目录>   输出首选 APN：id|apn|protocol|roaming|type
MODE="$1"
WANT="$2"          # 0 = 关闭系统 IPv6（默认），1 = 开启
STATE="$3"
# 写入 /proc/.../disable_ipv6 的值：关 → 1（禁用），开 → 0（恢复）
DIS=1
[ "$WANT" = "1" ] && DIS=0
IPV6_CONF=/proc/sys/net/ipv6/conf
IPV6_COOL=60
IPV6_TICK=5
IP=/system/bin/ip
[ -x "$IP" ] || IP=ip
PID_FILE="$STATE/loop.pid"
WANT_FILE="$STATE/want"
NET_FILE="$STATE/net"
LAST_FILE="$STATE/last"
APN_STATE="$STATE/apn.state"
APN_CACHE="$STATE/apn.current"
APN_LOCK="$STATE/apn.lock"
APN_LOCK_TIMEOUT=120
LOG="$STATE/log"

mkdir -p "$STATE" 2>/dev/null

# 清理旧版本遗留的带逗号损坏状态与多余临时文件
sanitize_state() {
  rm -f "$STATE/ipv6.want" "$STATE/ipv6.net" "$STATE/ipv6.last" 2>/dev/null
  if [ -f "$APN_CACHE" ] && grep -q ',|' "$APN_CACHE" 2>/dev/null; then
    rm -f "$APN_CACHE" 2>/dev/null
  fi
  if [ -f "$APN_STATE" ] && grep -q ',' "$APN_STATE" 2>/dev/null; then
    awk -F'|' 'BEGIN{OFS="|"} {
      gsub(/,$/, "", $1); gsub(/,$/, "", $2); gsub(/,$/, "", $3); gsub(/,$/, "", $4)
      if ($3 == "" || $3 == "IP") $3 = "IPV4V6"
      if ($4 == "" || $4 == "IP") $4 = "IPV4V6"
      if ($1 != "") print $1, $2, $3, $4
    }' "$APN_STATE" > "$APN_STATE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_STATE.tmp" 2>/dev/null &&
      mv -f "$APN_STATE.tmp" "$APN_STATE" 2>/dev/null
  fi
}

log() {
  echo "$(date '+%m-%d %H:%M:%S' 2>/dev/null) $*" >> "$LOG" 2>/dev/null
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
  return 0
}

# 热点 / USB 共享下游口：系统 dnsmasq 与 RA 自己管，绝不写它的 disable_ipv6
is_tether_if() {
  case "$1" in
    br[0-9]*|bridge*|ap[0-9]*|swlan*|softap*|rndis*|usb[0-9]*|bt-pan*|p2p*|wigig*|sipa_usb*) return 0 ;;
    wlan[0-9]*|eth[0-9]*)
      "$IP" -4 addr show dev "$1" 2>/dev/null | grep -Eq 'inet [0-9]+\.[0-9]+\.[0-9]+\.1/' && return 0 ;;
  esac
  return 1
}

# 永久豁免：lo / 模板 / 蜂窝（IMS 依赖 v6，只靠 APN 协议处理）/ 热点下游
is_exempt_if() {
  case "$1" in
    lo|all|default) return 0 ;;
    rmnet*|r_rmnet*|ccmni*|wwan*|pdp*|v4-rmnet*|radio*|cellular*) return 0 ;;
  esac
  is_tether_if "$1"
}

setv() {
  [ -e "$1" ] || return 0
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] || echo "$2" > "$1" 2>/dev/null
  return 0
}

apn_parse() {
  awk '
    /Row:/ && /_id=/ {
      id=""; apn=""; p=""; r=""; t=""
      for (i = 1; i <= NF; i++) {
        v = $i; sub(/,$/, "", v)
        if (v ~ /^_id=/) id = substr(v, 5)
        else if (v ~ /^apn=/) apn = substr(v, 5)
        else if (v ~ /^protocol=/) p = substr(v, 10)
        else if (v ~ /^roaming_protocol=/) r = substr(v, 18)
        else if (v ~ /^type=/) t = substr(v, 6)
      }
      if (id != "" && id != "NULL" && !(id in seen)) { seen[id] = 1; print id "|" apn "|" p "|" r "|" t }
    }'
}

# 每行：id|apn|protocol|roaming|type（同一 id 只输出一次）
apn_rows() {
  _proj="_id:apn:protocol:roaming_protocol:type"
  # 优先查默认主卡 preferapn（仅启动 1 个 app_process），为空时再并发查 subId/1..4
  _out=$(content query --uri content://telephony/carriers/preferapn --projection "$_proj" 2>/dev/null | apn_parse)
  if [ -z "$_out" ]; then
    _d="$STATE/apnq.$$"
    mkdir -p "$_d" 2>/dev/null || return 0
    for _n in 1 2 3 4; do
      content query --uri "content://telephony/carriers/preferapn/subId/$_n" --projection "$_proj" > "$_d/$_n" 2>/dev/null &
    done
    wait
    _out=$(cat "$_d"/* 2>/dev/null | apn_parse)
    rm -rf "$_d" 2>/dev/null
  fi
  if [ -n "$_out" ]; then
    printf '%s\n' "$_out" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
    printf '%s\n' "$_out"
  fi
  return 0
}

# 切换开关瞬间先乐观更新本地缓存，保证 UI 立即显示目标协议
apn_optimistic_cache() {
  [ -s "$APN_CACHE" ] || return 0
  if [ "$WANT" = "0" ]; then
    while IFS='|' read -r _id _apn _p _r _t; do
      [ -n "$_id" ] || continue
      case "$_t" in *ims*|*IMS*) continue ;; esac
      if [ "$_p" != "IP" ] || [ "$_r" != "IP" ]; then
        if ! grep -q "^$_id|" "$APN_STATE" 2>/dev/null; then
          echo "$_id|$_apn|$_p|$_r" >> "$APN_STATE"
          chmod 0644 "$APN_STATE" 2>/dev/null
        fi
      fi
    done < "$APN_CACHE"
    awk -F'|' 'BEGIN{OFS="|"} {
      if (tolower($5) !~ /ims/) { $3="IP"; $4="IP" }
      print
    }' "$APN_CACHE" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
  else
    awk -F'|' 'BEGIN{OFS="|"}
      NR==FNR {
        if ($1 != "") {
          orig_p[$1] = ($3 != "" && $3 != "IP") ? $3 : "IPV4V6"
          orig_r[$1] = ($4 != "" && $4 != "IP") ? $4 : "IPV4V6"
        }
        next
      }
      {
        if (tolower($5) !~ /ims/) {
          if ($1 in orig_p) { $3 = orig_p[$1]; $4 = orig_r[$1] }
          else {
            if ($3 == "" || $3 == "IP") { $3 = "IPV4V6" }
            if ($4 == "" || $4 == "IP") { $4 = "IPV4V6" }
          }
        }
        print
      }
    ' "$APN_STATE" "$APN_CACHE" > "$APN_CACHE.tmp" 2>/dev/null &&
      chmod 0644 "$APN_CACHE.tmp" 2>/dev/null &&
      mv -f "$APN_CACHE.tmp" "$APN_CACHE" 2>/dev/null
  fi
}

# APN 改写包含多次 content 查询/更新，并在实际变化后重附着数据。once 的后台任务
# 与紧随其后启动的 watch 没有天然时序保证：watch 可能在首次更新落库前读到旧协议，
# 从而把同一切换重复改写并重复断网。用 mkdir 的原子性串行化所有 APN 改写/还原；
# 后到者必须等先行者完成后再重新查询，届时已达目标值便直接跳过。
_apn_lock_token=""
apn_lock_acquire() {
  _apn_lock_waited=0
  while ! mkdir "$APN_LOCK" 2>/dev/null; do
    if [ "$_apn_lock_waited" -ge "$APN_LOCK_TIMEOUT" ]; then
      log "WARN APN 操作锁等待超时，强制接管残留锁"
      rm -rf "$APN_LOCK" 2>/dev/null
      _apn_lock_waited=0
      continue
    fi
    sleep 1
    _apn_lock_waited=$((_apn_lock_waited + 1))
  done
  _apn_lock_token="pid=$$"
  printf '%s\n' "$_apn_lock_token" > "$APN_LOCK/owner" 2>/dev/null
  return 0
}

apn_lock_release() {
  [ -n "$_apn_lock_token" ] || return 0
  if [ "$(cat "$APN_LOCK/owner" 2>/dev/null)" = "$_apn_lock_token" ]; then
    rm -rf "$APN_LOCK" 2>/dev/null
  fi
  _apn_lock_token=""
  return 0
}

# 不手动开关移动数据让新 APN 协议生效：content update 改动 carriers 后，框架的
# DataProfileManager 会监听到 APN 库变化并重估已连接的数据网络，协议属于
# ApnSetting 的比较字段，变化即判定 DATA_PROFILE_INVALID 并拆网重建——改库本身
# 就会让移动数据重连一次。脚本再 svc data disable/enable 等于第二次重连，
# 一次开关切换在状态栏表现为移动数据掉线两次。故这里只改库，不做重附着。

# 「系统 IPv6=关」：上网 APN 协议改为 IP（幂等；只写漂移的行；跳过 IMS）
# 写入后不信任 content 的输出文字，而是重新查询同一行，以实际值为准。
# 实际工作在 apn_lock 内执行，见 apn_apply 包装函数。
apn_apply_locked() {
  _rows=$(apn_rows)
  if [ -z "$_rows" ]; then
    log "WARN 未查询到首选 APN，未改写（可手动把 APN 协议设为 IPv4，效果相同）"
    return 1
  fi
  _changed=0; _fail=0
  while IFS='|' read -r _id _apn _p _r _t; do
    [ -n "$_id" ] || continue
    case "$_t" in *ims*|*IMS*) log "跳过 IMS 承载 id=$_id apn=$_apn"; continue ;; esac
    if [ "$_p" = "IP" ] && [ "$_r" = "IP" ]; then continue; fi
    if ! grep -q "^$_id|" "$APN_STATE" 2>/dev/null; then
      echo "$_id|$_apn|$_p|$_r" >> "$APN_STATE"
      chmod 0644 "$APN_STATE" 2>/dev/null
    fi
    _res=$(content update --uri content://telephony/carriers --where "_id=$_id" --bind protocol:s:IP --bind roaming_protocol:s:IP 2>&1)
    _now=$(apn_rows | grep "^$_id|" | head -1)
    case "$_now" in
      *"|IP|IP|"*) log "id=$_id apn=$_apn: $_p/$_r -> IP/IP（已校验）"; _changed=1 ;;
      *) log "WARN id=$_id apn=$_apn 写入后仍为 [$_now]，content 输出：$_res"; _fail=1 ;;
    esac
  done <<APN_ROWS_END
$_rows
APN_ROWS_END
  [ "$_fail" = "0" ]
}

apn_apply() {
  apn_lock_acquire
  apn_apply_locked
  _apn_rc=$?
  apn_lock_release
  return "$_apn_rc"
}

# 关态周期校验：首选 APN 若被系统或运营商写回 IPv4/IPv6，则重新改写（每 60 秒一次，见 watch 循环）
# 只改数据库：协议生效靠框架监听 APN 库变化后自行拆建数据网络（见 apn_apply 前的说明），
# watchdog 不做任何断网动作，避免一次切换后紧接着第二次重连。
apn_drift_check() {
  _rows=$(apn_rows)
  [ -n "$_rows" ] || return 0
  _bad=$(echo "$_rows" | awk -F'|' '$1 != "" && tolower($5) !~ /ims/ && ($3 != "IP" || $4 != "IP") {print $1}')
  if [ -n "$_bad" ]; then
    log "APN 协议漂移（id=$(echo $_bad | tr '\n' ' ')），重新改写"
    apn_apply
  fi
  return 0
}

# 「系统 IPv6=开」：按状态文件还原 protocol / roaming_protocol；其中 IPv4-only 的 IP/空值提升为 IPV4V6，状态文件缺失时按当前值兜底
# 实际工作在 apn_lock 内执行，见 apn_restore 包装函数。
apn_restore_locked() {
  _fail=0; _changed=0
  if [ -f "$APN_STATE" ]; then
    while IFS='|' read -r _id _apn _p _r; do
      [ -n "$_id" ] || continue
      if [ -z "$_p" ] || [ "$_p" = "IP" ]; then _p="IPV4V6"; fi
      # 保存的漫游若仍是 IPv4-only（IP/空），开启 IPv6 时提升为 IPV4V6。运营商默认
      # APN（如 ctnet）的 roaming_protocol 常为 IP，若原样还原就会出现协议已是
      # IPv4/IPv6、漫游仍 IPv4；已保存为 IPV6/IPV4V6 等非 IP 值时才按原值还原。
      case "$_r" in "" | "IP") _r="IPV4V6" ;; esac
      _res=$(content update --uri content://telephony/carriers --where "_id=$_id" --bind "protocol:s:$_p" --bind "roaming_protocol:s:$_r" 2>&1)
      _now=$(apn_rows | grep "^$_id|" | head -1)
      case "$_now" in
        "$_id|$_apn|$_p|$_r|"*) log "还原 id=$_id apn=$_apn: $_p/$_r（已校验）"; _changed=1 ;;
        *) log "WARN 还原 id=$_id apn=$_apn 后仍为 [$_now]，content 输出：$_res"; _fail=1 ;;
      esac
    done < "$APN_STATE"
    [ "$_fail" = "0" ] && rm -f "$APN_STATE" 2>/dev/null
  else
    # 兜底：若 apn.state 已被误删，只要协议或漫游仍是 IPv4-only（IP/空）就提升为
    # IPV4V6。旧版本可能已把 protocol 还原、却把 roaming 留在 IP 且删掉了状态文件，
    # 这里必须能单独修复漫游，否则开启后仍会出现协议双栈、漫游 IPv4。
    _rows=$(apn_rows)
    if [ -n "$_rows" ]; then
      while IFS='|' read -r _id _apn _p _r _t; do
        [ -n "$_id" ] || continue
        case "$_t" in *ims*|*IMS*) continue ;; esac
        _tp="$_p"; _tr="$_r"
        case "$_tp" in "" | "IP") _tp="IPV4V6" ;; esac
        case "$_tr" in "" | "IP") _tr="IPV4V6" ;; esac
        if [ "$_tp" != "$_p" ] || [ "$_tr" != "$_r" ]; then
          _res=$(content update --uri content://telephony/carriers --where "_id=$_id" --bind "protocol:s:$_tp" --bind "roaming_protocol:s:$_tr" 2>&1)
          _now=$(apn_rows | grep "^$_id|" | head -1)
          case "$_now" in
            "$_id|$_apn|$_tp|$_tr|"*) log "兜底还原 id=$_id apn=$_apn: $_tp/$_tr（已校验）"; _changed=1 ;;
            *) log "WARN 兜底还原 id=$_id apn=$_apn 后仍为 [$_now]，content 输出：$_res"; _fail=1 ;;
          esac
        fi
      done <<APN_RESTORE_END
$_rows
APN_RESTORE_END
    fi
  fi
  return 0
}

apn_restore() {
  apn_lock_acquire
  apn_restore_locked
  _apn_rc=$?
  apn_lock_release
  return "$_apn_rc"
}

# 开态重应用时的 APN 体检：任一非 IMS 行的协议或漫游仍为 IPv4-only（IP/空）就需要修复
apn_ipv6_needed() {
  _rows=$(apn_rows)
  [ -n "$_rows" ] || return 1
  printf '%s\n' "$_rows" | awk -F'|' '$1 != "" && tolower($5) !~ /ims/ && ($3 == "" || $3 == "IP" || $4 == "" || $4 == "IP") { found=1 } END { exit(found ? 0 : 1) }'
}

# 网络指纹 = 路由表 + 网卡集合（切网 / 飞行模式 / 换卡时变化）
fingerprint() {
  _cur=""
  while IFS= read -r _l || [ -n "$_l" ]; do _cur="$_cur$_l "; done < /proc/net/route 2>/dev/null
  for _f in "$IPV6_CONF"/*/disable_ipv6; do
    [ -e "$_f" ] || continue
    _i=${_f%/disable_ipv6}; _cur="$_cur${_i##*/} "
  done
  printf '%s' "$_cur"
}

sync_once() {
  [ -d "$IPV6_CONF" ] || return 0
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
    # 开态：只更新指纹；但 once 重应用时若 APN 仍有 IPv4-only 字段（旧版本遗留的
    # 协议双栈/漫游 IPv4），借道 flip 路径在后台修复一次，已达标则不写库。
    [ "$_cur" = "$_netprev" ] || printf '%s' "$_cur" > "$NET_FILE"
    if [ "$MODE" = "once" ] && apn_ipv6_needed; then
      _need=1; _flip=1
    else
      return 0
    fi
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

  # 第一步（毫秒级同步完成）：非蜂窝、非豁免网卡只写值不对的（lo / all / default / 蜂窝 / 热点跳过）
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

  if [ "$_flip" = "1" ] && [ -s "$APN_CACHE" ]; then
    apn_optimistic_cache
  fi

  # 第二步（蜂窝 APN 改写 + 开启时 ndc 通知）：
  # once 模式下放后台异步执行，使开关切换毫秒级返回；watch 循环内顺序执行。
  # 这里只改 APN 数据库，不手动重附着数据：改库会触发框架重估并拆建数据网络
  # 让新协议生效（恰好一次重连）；watch 的切网/漂移修复同理只改库。
  _post_sync() {
    if [ "$WANT" = "0" ]; then
      if [ "$_flip" = "1" ] || [ "$_netchg" = "1" ]; then apn_apply; fi
    else
      if [ "$_flip" = "1" ]; then apn_restore; fi
    fi

    if [ "$WANT" = "1" ] && [ -n "$_changed" ]; then
      if command -v ndc >/dev/null 2>&1; then
        for _i in $_changed; do ndc interface ipv6 "$_i" enable >/dev/null 2>&1; done
      fi
      for _i in $_changed; do
        case "$_i" in rmnet*|ccmni*|wwan*|r_rmnet*) "$IP" link set "$_i" down 2>/dev/null ;; esac
      done
      for _i in $_changed; do
        case "$_i" in rmnet*|ccmni*|wwan*|r_rmnet*) "$IP" link set "$_i" up 2>/dev/null ;; esac
      done
    fi
  }

  if [ "$MODE" = "once" ]; then
    ( _post_sync ) </dev/null >>"$LOG" 2>&1 &
  else
    _post_sync
  fi
  return 0
}

kill_loop() {
  for _pf in "$PID_FILE" "$STATE/watch.pid"; do
    _old=$(cat "$_pf" 2>/dev/null)
    if [ -n "$_old" ] && [ "$_old" != "$$" ]; then kill "$_old" 2>/dev/null; fi
    rm -f "$_pf" 2>/dev/null
  done
  return 0
}

sanitize_state
case "$MODE" in
  once)
    kill_loop
    sync_once
    ;;
  watch)
    kill_loop
    echo "$$" > "$PID_FILE"
    log "常驻对账启动（pid $$，${IPV6_TICK}s 一拍）"
    # watch 常跟在 once 之后启动，先睡一拍避免与 once 的后台 APN 任务并发冲突
    _tick=0
    while [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; do
      sleep "$IPV6_TICK"
      [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] || exit 0
      sync_once
      _tick=$((_tick + 1))
      # 关态每 12 拍（约 60 秒）校验一次 APN；开态不做
      if [ "$WANT" = "0" ] && [ $((_tick % 12)) -eq 0 ]; then apn_drift_check; fi
    done
    ;;
  status)
    apn_rows
    ;;
esac
exit 0
