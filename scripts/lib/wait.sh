#!/usr/bin/env bash
# Wait-for-service helpers

# wait_for_url <url> [timeout_s] [expected_status]
wait_for_url() {
  local url="$1" timeout="${2:-60}" expected="${3:-200}"
  local start
  start=$(date +%s)
  while true; do
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "$expected" ]]; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 1
  done
}

# wait_for_port <host> <port> [timeout_s]
wait_for_port() {
  local host="$1" port="$2" timeout="${3:-30}"
  local start
  start=$(date +%s)
  while true; do
    if (echo > "/dev/tcp/$host/$port") 2>/dev/null; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 1
  done
}

# wait_for_docker <container> [timeout_s]
wait_for_docker() {
  local c="$1" timeout="${2:-60}"
  local start
  start=$(date +%s)
  while true; do
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    case "$status" in
      running) return 0 ;;
      exited|dead) return 1 ;;
    esac
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 1
  done
}

# wait_for_docker_healthy <container> [timeout_s]
wait_for_docker_healthy() {
  local c="$1" timeout="${2:-60}"
  local start
  start=$(date +%s)
  while true; do
    local h
    h=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "missing")
    if [[ "$h" == "healthy" ]]; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 1
  done
}
