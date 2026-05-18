#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PRIMARY_IP="172.18.98.9"
STANDBY_IP="172.30.98.9"

NGINX_CONTAINER="elastic-nginx-1"
NGINX_CONF="/elastdocker/nginx/nginx.conf"

STATE_FILE="/elastdocker/nginx/failover.state"
FAIL_COUNT_FILE="/elastdocker/nginx/failover.fail_count"
RISE_COUNT_FILE="/elastdocker/nginx/failover.rise_count"
LOCK_FILE="/tmp/nginx-failover.lock"

# 每分钟执行一次时，5 表示连续约 5 分钟主节点两个端口都 TCP connect 不上才切备。
FAIL_THRESHOLD=5

# 在 standby 状态下，主节点两个端口恢复 1 次检查成功就切回主。
RISE_THRESHOLD=1

CONNECT_TIMEOUT=2

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log() {
  echo "[$(date '+%F %T%z')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: required command not found: $1"
    exit 1
  }
}

require_cmd docker
require_cmd flock
require_cmd timeout
require_cmd sed
require_cmd grep
require_cmd mktemp

tcp_check() {
  local host="$1"
  local port="$2"

  if command -v nc >/dev/null 2>&1; then
    timeout "$CONNECT_TIMEOUT" nc -z -w "$CONNECT_TIMEOUT" "$host" "$port" >/dev/null 2>&1
  else
    timeout "$CONNECT_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1
  fi
}

primary_all_up() {
  tcp_check "$PRIMARY_IP" 9200 && tcp_check "$PRIMARY_IP" 8220
}

primary_all_down() {
  ! tcp_check "$PRIMARY_IP" 9200 && ! tcp_check "$PRIMARY_IP" 8220
}

get_state() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "primary"
}

set_state() {
  echo "$1" > "$STATE_FILE"
}

get_count() {
  local file="$1"
  [ -f "$file" ] && cat "$file" || echo 0
}

set_count() {
  local file="$1"
  local value="$2"
  echo "$value" > "$file"
}

reset_counts() {
  set_count "$FAIL_COUNT_FILE" 0
  set_count "$RISE_COUNT_FILE" 0
}

render_target() {
  local target_ip="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  sed -E \
    -e "s|^[[:space:]]*proxy_pass[[:space:]]+[^;]+:9200;[[:space:]]*# managed-by-failover TARGET_9200|        proxy_pass ${target_ip}:9200; # managed-by-failover TARGET_9200|" \
    -e "s|^[[:space:]]*proxy_pass[[:space:]]+[^;]+:8220;[[:space:]]*# managed-by-failover TARGET_8220|        proxy_pass ${target_ip}:8220; # managed-by-failover TARGET_8220|" \
    "$NGINX_CONF" > "$tmp_file"

  if ! grep -Fq "proxy_pass ${target_ip}:9200; # managed-by-failover TARGET_9200" "$tmp_file"; then
    log "ERROR: failed to render TARGET_9200"
    rm -f "$tmp_file"
    exit 1
  fi

  if ! grep -Fq "proxy_pass ${target_ip}:8220; # managed-by-failover TARGET_8220" "$tmp_file"; then
    log "ERROR: failed to render TARGET_8220"
    rm -f "$tmp_file"
    exit 1
  fi

  # Preserve inode for Docker single-file bind mount.
  cat "$tmp_file" > "$NGINX_CONF"
  rm -f "$tmp_file"
}

reload_nginx() {
  docker exec "$NGINX_CONTAINER" nginx -t
  docker exec "$NGINX_CONTAINER" nginx -s reload
}

switch_to() {
  local mode="$1"
  local target_ip
  local backup_file

  if [ "$mode" = "primary" ]; then
    target_ip="$PRIMARY_IP"
  else
    target_ip="$STANDBY_IP"
  fi

  backup_file="${NGINX_CONF}.bak.$(date '+%Y%m%d%H%M%S')"

  log "Switching nginx target to $mode: $target_ip"
  cp -a "$NGINX_CONF" "$backup_file"

  render_target "$target_ip"

  if reload_nginx; then
    set_state "$mode"
    reset_counts
    log "Switched to $mode successfully."
  else
    log "ERROR: nginx reload failed. Rolling back config."
    cat "$backup_file" > "$NGINX_CONF"
    reload_nginx || true
    exit 1
  fi
}

state="$(get_state)"

if [ "$state" = "primary" ]; then
  if primary_all_down; then
    fail_count="$(get_count "$FAIL_COUNT_FILE")"
    fail_count=$((fail_count + 1))
    set_count "$FAIL_COUNT_FILE" "$fail_count"

    log "Primary 9200 and 8220 are both down. fail_count=$fail_count/$FAIL_THRESHOLD"

    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
      switch_to "standby"
    fi
  else
    set_count "$FAIL_COUNT_FILE" 0
    log "Primary is reachable. Stay on primary."
  fi

elif [ "$state" = "standby" ]; then
  if primary_all_up; then
    rise_count="$(get_count "$RISE_COUNT_FILE")"
    rise_count=$((rise_count + 1))
    set_count "$RISE_COUNT_FILE" "$rise_count"

    log "Primary 9200 and 8220 recovered. rise_count=$rise_count/$RISE_THRESHOLD"

    if [ "$rise_count" -ge "$RISE_THRESHOLD" ]; then
      switch_to "primary"
    fi
  else
    set_count "$RISE_COUNT_FILE" 0
    log "Primary is not fully recovered. Stay on standby."
  fi

else
  log "Unknown state: $state. Reset to primary."
  switch_to "primary"
fi
