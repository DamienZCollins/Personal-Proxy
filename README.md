# Personal-Proxy

两个协议的部署指南：**VLESS**、**Hysteria2**。

## 交给 AI Agent 部署

如果由 AI Agent 执行部署，**先让它完整阅读 [`AGENTS.md`](./AGENTS.md)**，再动手。

该文件是 Agent 的操作规范，包含：

| 章节 | 作用 |
|---|---|
| 架构边界 | 哪些能做，哪些必须先经你确认（如重启服务、改防火墙）|
| 安全模型 | 占位符规则、密钥存放、提交前自检 |
| 验证清单 | 每次变更后必须按顺序执行的检查项 |
| 版本漂移流程 | 上游出现破坏性变更时，先说明差异再由你决定，并回提 Issue/PR |
| 高频陷阱 | 已知会导致静默失败的配置错误 |

Agent 在开始前会主动查询上游最新版本，与本仓库 [`VERSIONS.md`](./VERSIONS.md) 的记录比对：

- **无破坏性变更** → 按本文档方案配置
- **有破坏性变更** → 指出差异与影响，由你决定采用哪种，不擅自套用旧方案

## 手动部署

本文档面向人类阅读，按「两种协议 → 服务端配置 → 客户端配置」组织，所有命令可直接复制执行。

> 仓库不含任何真实节点、IP、域名或密钥，全部用 `{{PLACEHOLDER}}` 占位。

---

# 一、两种协议

## 对比

| | **VLESS** | **Hysteria2** |
|---|---|---|
| 传输 | TCP 443 | UDP 443 |
| 需要域名 | ❌ | ❌ |
| 需要证书 | ❌（REALITY 借用） | 自签即可 |
| 抗主动探测 | ⭐⭐⭐ 最强 | ⭐⭐ |
| 弱网性能 | ⭐⭐ | ⭐⭐⭐ 最强 |
| 首次连接 | 较慢（多一次握手） | 快 |
| 防火墙友好度 | ⭐⭐⭐ TCP 443 几乎都放行 | ⭐ 严格网络常封 UDP |
| 成熟度 | ⭐⭐⭐ 最稳定 | ⭐⭐⭐ |

## 各自解决什么问题

```mermaid
flowchart TB
    A[你的网络环境] --> B{UDP 通畅?}
    B -->|是| C["Hysteria2<br/>弱网性能最好"]
    B -->|否| D["VLESS + REALITY<br/>走 TCP 443"]
    C -.->|"TCP 也通?"| D2["可同时部署<br/>客户端按需切换"]
```

- **VLESS** — 伪装成真实网站，走 TCP。解决「UDP 被限制」或「需要最强伪装」
- **Hysteria2** — 基于 QUIC，走 UDP。解决「弱网、丢包严重」或「TCP 受限」

两者互补，可同时部署。

## VLESS 原理

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as VPS
    participant T as 真实站点(bing.com)
    C->>S: TLS 握手 (SNI=bing.com)
    S->>T: 转发握手
    T-->>S: 真实证书
    S-->>C: 原样返回
    Note over C,S: 审查者看到访问的是 bing.com<br/>认证通过后转为代理流量
```

用 **REALITY** 借用真实站点的证书和握手，**不需要自己申请证书**，也无法被主动探测识别。

配 `xtls-rprx-vision` 流控消除 TLS-in-TLS 特征。

## Hysteria2 原理

```mermaid
flowchart LR
    C[客户端] -->|"QUIC / UDP 443"| S["VPS: hysteria 服务端"]
    S --> I[Internet]
```

基于 QUIC（UDP），自带 **Brutal** 拥塞控制，丢包严重时仍能跑满带宽。配 **Salamander** 混淆可干扰运营商的 QUIC 流量识别。

---

# 二、服务端配置

## 通用前置

### SSH 安全登录

**先确保密钥登录可用，再动任何网络配置**，否则可能把自己锁在门外。

```bash
ssh-keygen -t ed25519 -C "proxy-vps"
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@{{VPS_IP}}
```

本地 `~/.ssh/config`：

```sshconfig
Host {{NODE_NAME}}
    HostName {{VPS_IP}}
    User root
    Port {{SSH_PORT}}
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

验证无密码登录成功后，才考虑禁用密码认证：

```bash
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

> ⚠️ 改前先开第二个终端确认密钥能登录。建议同时把 SSH 改到非标准端口。

### 端口规划

| 组合 | 是否冲突 |
|---|---|
| Xray TCP 443 + Hysteria UDP 443 | ✅ 不冲突（协议号不同）|

两个协议可以都用 443：VLESS 占 TCP 443，Hysteria2 占 UDP 443。

---

## 2.1 VLESS 服务端

### 安装 Xray

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
xray version
```

### 生成密钥

```bash
# REALITY 密钥对
xray x25519
# 输出：PrivateKey（服务端用）+ Password/PublicKey（客户端用）

# UUID
xray uuid
```

> ⚠️ 公私钥不能写反：服务端存私钥，客户端存公钥。

### 选择目标站点

`{{REALITY_TARGET}}` 必须满足：

| 要求 | 说明 |
|---|---|
| 境外站点 | 不能是国内站点 |
| 支持 TLSv1.3 + H2 | 必须 |
| 域名不重定向 | `example.com` → `www.example.com` 这种不行 |
| 延迟低 | 与 VPS 地理位置近 |

推荐类型：`www.microsoft.com`、`dl.google.com` 等。

验证目标可用：

```bash
openssl s_client -connect {{REALITY_TARGET}}:443 -servername {{REALITY_TARGET}} \
  -tls1_3 -alpn h2 </dev/null 2>&1 | grep -E "Protocol|ALPN"
# 应显示 TLSv1.3 和 ALPN protocol: h2
```

### 配置

`/usr/local/etc/xray/config.json`：

```jsonc
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "{{UUID}}",
            // ★ 必须带 flow，裸 VLESS 已被 Xray 弃用
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        // 旧版写 "tcp"，新版称 "raw"，二者兼容
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          // 新版字段名为 target，旧版 dest
          "dest": "{{REALITY_TARGET}}:443",
          "serverNames": ["{{REALITY_TARGET}}"],
          "privateKey": "{{REALITY_PRIVATE_KEY}}",
          "shortIds": ["{{REALITY_SHORT_ID}}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
```

### 启动与自检

```bash
systemctl enable --now xray
systemctl is-active xray
ss -tlnp | grep :443
journalctl -u xray -n 30 --no-pager

# 服务端自检：应返回目标站点真实证书
openssl s_client -connect {{LOCALHOST}}:443 -servername {{REALITY_TARGET}} </dev/null 2>&1 \
  | grep -E "subject=|Verify return code"
```

---

## 2.2 Hysteria2 服务端

### 安装

```bash
bash <(curl -fsSL https://get.hy2.sh/)
```

### 生成自签证书

```bash
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
  -subj "/CN={{SERVER_NAME}}" -days 3650
chmod 600 /etc/hysteria/key.pem
chown -R hysteria:hysteria /etc/hysteria
```

> 自签证书完全可用，客户端跳过校验即可，**不需要申请 Let's Encrypt**。

### 配置

`/etc/hysteria/config.yaml`：

```yaml
listen: :{{HY2_PORT}}

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: password
  password: {{HY2_PASSWORD}}

obfs:
  type: salamander
  salamander:
    password: {{HY2_OBFS_PASSWORD}}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
```

### 启动

```bash
systemctl enable --now hysteria-server
systemctl is-active hysteria-server
ss -ulnp | grep :{{HY2_PORT}}
journalctl -u hysteria-server -n 30 --no-pager
```

若无 systemd unit（手动装的二进制），创建 `/etc/systemd/system/hysteria-server.service`：

```ini
[Unit]
Description=Hysteria Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
User=hysteria
Group=hysteria
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
useradd -r -s /sbin/nologin hysteria || true
systemctl daemon-reload && systemctl enable --now hysteria-server
```

---

# 三、客户端配置

统一使用 **Clash Verge Rev**（mihomo 内核，纯 YAML 配置），两个协议均原生支持。

## 配置文件位置

```text
Windows: %APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\
macOS:   ~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/
Linux:   ~/.config/io.github.clash-verge-rev.clash-verge-rev/profiles/
```

## 3.1 VLESS 客户端

```yaml
proxies:
  - name: "VLESS"
    type: vless
    server: {{VPS_IP}}
    port: 443
    uuid: {{UUID}}
    network: tcp
    tls: true
    udp: true
    # ★ 必须与服务端 flow 一致
    flow: xtls-rprx-vision
    servername: {{REALITY_TARGET}}
    client-fingerprint: chrome
    reality-opts:
      public-key: {{REALITY_PUBLIC_KEY}}
      short-id: {{REALITY_SHORT_ID}}
```

## 3.2 Hysteria2 客户端

```yaml
proxies:
  - name: "HY2"
    type: hysteria2
    server: {{VPS_IP}}
    port: {{HY2_PORT}}
    password: {{HY2_PASSWORD}}
    # 自签证书必须为 true
    skip-cert-verify: true
    sni: {{SERVER_NAME}}
    # 按 VPS 实际带宽填写
    up: "{{UP_MBPS}}"
    down: "{{DOWN_MBPS}}"
    obfs: salamander
    obfs-password: {{HY2_OBFS_PASSWORD}}
    alpn:
      - h3
```

## 3.3 组合配置

把两个节点放入同一份配置文件，配合分组与分流规则：

```yaml
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies: ["VLESS", "HY2", "♻️ 自动选择"]

  - name: "♻️ 自动选择"
    type: url-test
    proxies: ["VLESS", "HY2"]
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50

  - name: "🤖 AI 服务"
    type: select
    proxies: ["🚀 节点选择", "WARP"]

rules:
  # 局域网直连
  - GEOIP,PRIVATE,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve

  # AI 服务走独立出口（避免机房 IP 风控）
  - DOMAIN-SUFFIX,openai.com,🤖 AI 服务
  - DOMAIN-SUFFIX,chatgpt.com,🤖 AI 服务
  - DOMAIN-SUFFIX,oaistatic.com,🤖 AI 服务
  - DOMAIN-SUFFIX,oaiusercontent.com,🤖 AI 服务
  - DOMAIN-SUFFIX,anthropic.com,🤖 AI 服务
  - DOMAIN-SUFFIX,claude.ai,🤖 AI 服务
  - DOMAIN-SUFFIX,gemini.google.com,🤖 AI 服务
  - DOMAIN-SUFFIX,aistudio.google.com,🤖 AI 服务
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com,🤖 AI 服务

  - MATCH,🚀 节点选择
```

完整示例见 [`examples/client-mihomo.yaml`](./examples/client-mihomo.yaml)。

## 3.4 验证

```bash
curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 \
  --socks5-hostname {{LOCALHOST}}:7897 https://www.gstatic.com/generate_204
# 期望 204
```

## 3.5 客户端自动化（可选）

Clash Verge 支持 REST API。

**前置**：设置 → 外部控制 → 开启，记下监听地址与密钥。

```bash
API="http://{{CLASH_API_HOST}}:9097"
KEY="{{CLASH_API_KEY}}"

# 查状态
curl -H "Authorization: Bearer $KEY" "$API/version"
curl -H "Authorization: Bearer $KEY" "$API/proxies"
curl -H "Authorization: Bearer $KEY" "$API/rules"

# 切节点（返回 204 表示成功）
curl -X PUT -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
     -d '{"name":"节点名"}' "$API/proxies/分组名"

# 测延迟
curl -H "Authorization: Bearer $KEY" \
     "$API/proxies/节点名/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
```

> 节点名含 emoji 或中文时必须 URL 编码。

---

# 排障

## 分层验证顺序

```text
1. 服务端进程活着        systemctl is-active
2. 端口在监听            ss -tulnp
3. 服务端本机自连可用    openssl s_client 连 {{LOCALHOST}}
4. 客户端能连上服务端    tcpdump 看 SYN/SYN-ACK
5. 客户端能出网          curl --socks5 访问外部
6. 延迟合理              REST API 测速
```

## ⚠️ 先确认本地没开 TUN

客户端开启 TUN 后接管全部流量，此时任何「直连测试」实际都走了代理，会得到 **1ms 延迟、1 跳直达**的假象。

```powershell
# Windows
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric
Find-NetRoute -RemoteIPAddress {{VPS_IP}}
```

```bash
# Linux / macOS
ip route get {{VPS_IP}}
```

若 `InterfaceAlias` 是 `singbox_tun` / `clash_tun` / `Mihomo`，**测试结果无效**。

## 服务端抓包判读

```bash
tcpdump -n -i any "host {{CLIENT_IP}} and tcp port 443" -c 20 -v
```

| 现象 | 结论 | 处理 |
|---|---|---|
| SYN 未到达 | 去程阻断 / 端口被过滤 | 换端口验证；或改用 Hysteria2 走 UDP |
| SYN 到达、无 SYN-ACK | 服务端未监听 / 本机防火墙 | 查 `ss -tlnp`、`iptables -L -n` |
| SYN 到达、SYN-ACK 已发、客户端仍超时 | 回程阻断 | 换 IP，或改用 Hysteria2 |

## 高频问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `x509: certificate signed by unknown authority` | 自签证书未跳过校验 | mihomo 设 `skip-cert-verify: true` |
| 本机自连成功、外部全失败 | 进程未重启，配置漂移 | `systemctl restart xray` |
| 警告 `VLESS with no Flow is deprecated` | 裸 VLESS 已弃用 | 加 `flow: "xtls-rprx-vision"` |
| 端口可达但协议不通 | 可能被中间设备代答 | 必须做端到端验证 |
| VLESS 换端口后更快被封 | 官方明确警告 | 坚持用 443 |
| Hysteria2 连接不稳定 | UDP 被限速 | 检查 Salamander 混淆是否启用 |

## 配置不能跨内核复制

| 功能 | Xray | mihomo |
|---|---|---|
| 跳过证书校验 | `pinnedPeerCertSha256`（字符串） | `skip-cert-verify: true` |
| Flow 字段 | `settings.clients[].flow` | `flow: xtls-rprx-vision` |

---

# 反模式清单

| ❌ 不要这样做 | 为什么 |
|---|---|
| 先用密码登录，之后再改密钥 | 公网暴露会被持续爆破 |
| 改防火墙前不确认 SSH 端口 | 可能直接锁死自己 |
| **裸 VLESS 不配 Flow** | 已弃用，抗检测能力差 |
| VLESS+REALITY 跑在非 443 端口 | 官方警告会加速 IP 被封 |
| 跨内核复制配置 | 字段名不同，会静默失败 |
| 假设 TCP 端口通 = 服务可用 | 裸连通过不代表协议层能跑 |
| 改完配置不重启进程 | 磁盘与内存配置不一致 |
| 为省事用密码认证 SSH | 公网暴露风险极高 |

---

# 版本与安全

**最后核对：2026-11-01** ｜ 详见 [`VERSIONS.md`](./VERSIONS.md)

| 组件 | 当前版本 | 发布 |
|---|---|---|
| Xray-core | v26.10.31 | 2026-10-31 |
| Hysteria2 | v2.x | — |
| mihomo | v1.19.33 | 2026-10-21 |
| Clash Verge Rev | v2.5.8 | 2026-10-09 |

## ⚠️ 安全公告

**Xray v26.10.31 是紧急安全更新**：Linux 内核被爆出监听 IPv4 MPTCP 极易被远程利用获取 root 权限，而 Go 1.24+ 默认开启 MPTCP。该版本默认关闭 MPTCP 以减小攻击面。

**建议**：尽快升级 Xray 至 v26.10.31+，并同步更新 Linux 内核。

## 破坏性变更

| 组件 | 变更 | 替代 |
|---|---|---|
| Xray | 裸 VLESS（无 Flow）弃用 | 加 `flow: "xtls-rprx-vision"` |
| Xray | 移除 `allowInsecure` | `pinnedPeerCertSha256` |
| Xray | `tcp` 传输改称 `raw` | 旧名仍兼容 |
| Xray | `dest` 改称 `target` | 旧名仍兼容 |

---

# 参考资料

- Xray-core — <https://github.com/XTLS/Xray-core>
- REALITY 文档 — <https://xtls.github.io/config/transports/reality.html>
- Xray 官方示例 — <https://github.com/XTLS/Xray-examples>
- VLESS Flow 迁移 — <https://github.com/XTLS/Xray-core/discussions/5568>
- Hysteria2 — <https://v2.hysteria.network/>
- mihomo 文档 — <https://wiki.metacubex.one>
- Clash Verge Rev — <https://github.com/clash-verge-rev/clash-verge-rev>
- AGENTS.md 规范 — <https://agents.md>