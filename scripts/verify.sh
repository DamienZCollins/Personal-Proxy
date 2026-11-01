#!/usr/bin/env bash
# 只读连通性验证脚本（A 层：不修改任何服务端状态）
#
# 用法：
#   bash scripts/verify.sh --host <VPS_IP> [--port 443] [--type tcp|udp]
#                          [--socks <host:port>] [--timeout 8]
#
# 退出码：
#   0 = 全部通过
#   1 = 有检查项失败

set -uo pipefail

HOST=""
PORT="443"
TYPE="tcp"
SOCKS=""
TIMEOUT=8
FAIL=0

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)    HOST="${2:-}"; shift 2 ;;
    --port)    PORT="${2:-}"; shift 2 ;;
    --type)    TYPE="${2:-}"; shift 2 ;;
    --socks)   SOCKS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

[[ -z "$HOST" ]] && { echo "错误：缺少 --host"; usage; }

pass() { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; FAIL=1; }
info() { echo "  [..]   $1"; }

echo "=== 目标: $HOST (${TYPE^^} $PORT) ==="
echo

# ── 1. DNS 解析 ────────────────────────────────────────────────
echo "1. DNS 解析"
if getent hosts "$HOST" >/dev/null 2>&1 || [[ "$HOST" =~ ^[0-9.]+$ ]]; then
  pass "$HOST 可解析"
else
  fail "$HOST 无法解析"
fi
echo

# ── 2. 端口可达性 ──────────────────────────────────────────────
echo "2. 端口可达性"
if [[ "$TYPE" == "tcp" ]]; then
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w "$TIMEOUT" "$HOST" "$PORT" 2>/dev/null; then
      pass "TCP $PORT 可达"
    else
      fail "TCP $PORT 不可达"
    fi
  elif command -v timeout >/dev/null 2>&1; then
    if timeout "$TIMEOUT" bash -c "echo >/dev/tcp/$HOST/$PORT" 2>/dev/null; then
      pass "TCP $PORT 可达"
    else
      fail "TCP $PORT 不可达"
    fi
  else
    info "缺少 nc / timeout，跳过"
  fi
else
  if command -v nc >/dev/null 2>&1 && nc -zu -w "$TIMEOUT" "$HOST" "$PORT" 2>/dev/null; then
    pass "UDP $PORT 已发送探测包（UDP 无连接语义，仅供参考）"
  else
    info "UDP 无法可靠探测，需端到端验证"
  fi
fi
echo

# ── 3. TLS 证书（仅 TCP）───────────────────────────────────────
echo "3. TLS 证书检查"
if [[ "$TYPE" == "tcp" ]] && command -v openssl >/dev/null 2>&1; then
  CERT=$(timeout "$TIMEOUT" openssl s_client -connect "$HOST:$PORT" -servername "$HOST" </dev/null 2>/dev/null)
  if [[ -n "$CERT" ]]; then
    SUBJ=$(echo "$CERT" | grep -m1 "subject=" | sed 's/.*subject=//')
    ISSUER=$(echo "$CERT" | grep -m1 "issuer=" | sed 's/.*issuer=//')
    info "subject: $SUBJ"
    info "issuer : $ISSUER"
    if [[ "$SUBJ" == "$ISSUER" ]]; then
      info "自签证书 → 客户端需跳过校验 (insecure / pinnedPeerCertSha256)"
    fi
    pass "TLS 握手成功"
  else
    info "TLS 握手失败（可能非 TLS 端口，或服务未就绪）"
  fi
else
  info "跳过"
fi
echo

# ── 4. 端到端出网（可选，需本地 SOCKS）─────────────────────────
echo "4. 端到端出网"
if [[ -n "$SOCKS" ]] && command -v curl >/dev/null 2>&1; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$((TIMEOUT*2))" \
         --socks5-hostname "$SOCKS" https://www.gstatic.com/generate_204 2>/dev/null)
  if [[ "$CODE" == "204" ]]; then
    pass "经 $SOCKS 出网正常 (204)"
    IP=$(curl -s --max-time "$((TIMEOUT*2))" --socks5-hostname "$SOCKS" https://api.ipify.org 2>/dev/null)
    [[ -n "$IP" ]] && info "出口 IP: $IP"
  else
    fail "经 $SOCKS 出网失败 (返回 $CODE)"
  fi
else
  info "未提供 --socks，跳过"
fi
echo

# ── 5. TUN 干扰提示 ────────────────────────────────────────────
echo "5. 本地路由提示"
if ip route get "$HOST" 2>/dev/null | grep -qiE 'tun|utun|clash|mihomo'; then
  info "⚠️  流量可能经过 TUN 接口，直连测试结果不可信"
else
  pass "未检测到 TUN 接管该目标"
fi
echo

# ── 汇总 ───────────────────────────────────────────────────────
if [[ $FAIL -eq 0 ]]; then
  echo "=== 结果：通过 ==="
  exit 0
else
  echo "=== 结果：有失败项，见上方 [FAIL] ==="
  exit 1
fi
