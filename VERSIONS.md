# 版本基线

**最后核对：2026-11-01**

| 组件 | 基线版本 | 发布时间 | 用途 |
|---|---|---|---|
| Xray-core | v26.10.31 | 2026-10-31 | 服务端：VLESS + REALITY |
| hysteria | v2.x | — | 服务端：Hysteria2 |
| mihomo | v1.19.33 | 2026-10-21 | 客户端内核 |
| Clash Verge Rev | v2.5.8 | 2026-10-09 | 客户端 GUI |

> 版本会随时间过时。Agent 部署前应重新查询，见 `AGENTS.md` 第 8 节。

---

## 安全公告

### Xray v26.10.31（2026-10-31）— 建议尽快升级

Linux 内核被爆出监听 IPv4 MPTCP 极易被远程利用获取 root 权限，而 Go 1.24+ 默认开启 MPTCP。该版本默认关闭 MPTCP 以减小攻击面。

影响范围不止 Linux 服务端：安卓客户端若 Socks / HTTP 入站开启了「允许来自局域网的连接」也存在风险。

**建议**：升级 Xray 至 v26.10.31 或更高，并同步更新 Linux 内核以从根源修复。

---

## 破坏性变更记录

| 组件 | 变更 | 影响与替代 |
|---|---|---|
| Xray | 裸 VLESS（无 Flow）弃用 | 加 `"flow": "xtls-rprx-vision"` |
| Xray | 移除 `allowInsecure` | 改用 `pinnedPeerCertSha256`（字符串，非数组）|
| Xray | `verifyPeerCertByName` 对自签无效 | 仅校验域名不信任签名，自签用证书固定 |
| Xray | 传输层 `tcp` 明确称为 `raw` | 旧名仍兼容，非破坏性 |
| Xray | `realitySettings.dest` → `target` | 旧名仍兼容 |

---

## 协议现状（2026-11）

| 协议 | 状态 | 定位 |
|---|---|---|
| VLESS + REALITY + Vision | ✅ 主流推荐 | 直连首选，伪装性最好 |
| Hysteria2 | ✅ 主流 | UDP 场景性能最好 |
| VLESS 无 Flow | ⚠️ 已弃用 | 尽快迁移 |

---

## 自行核对

```bash
gh api repos/XTLS/Xray-core/releases/latest --jq '.tag_name, .published_at'
gh api repos/apernet/hysteria/releases/latest --jq '.tag_name, .published_at'
gh api repos/MetaCubeX/mihomo/releases/latest --jq '.tag_name, .published_at'
gh api repos/clash-verge-rev/clash-verge-rev/releases/latest --jq '.tag_name'
```

原子订阅源（含预发布，注意区分 alpha）：

```bash
curl -s https://github.com/XTLS/Xray-core/releases.atom | grep -o '<title>[^<]*</title>' | head -3
```