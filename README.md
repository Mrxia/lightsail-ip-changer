# Lightsail IP Changer (Docker 版)

自动检测 AWS Lightsail 静态 IP 是否被墙，被墙则自动更换 IP、更新 Cloudflare 解析，并通过 Telegram 通知。

基于 [angelsky11/change-lightsail-ip](https://github.com/angelsky11/change-lightsail-ip)（2020）改良，主要变化：

| 原版 | 本项目 |
|---|---|
| `ping -c 30` 检测（ICMP） | **TCP 端口探测**（GFW 现多为 TCP 端口级封锁，ICMP 通≠没被墙） |
| 连续 30 次 ping 全丢才判定 | `FAIL_THRESHOLD` 次连续 TCP 失败判定（默认 5 次，防抖动误判） |
| Server酱（sc.ftqq.com 旧接口） | **Telegram Bot** 通知 |
| 更换 IP 后结束 | **Cloudflare A 记录自动更新** + TG 通知推送新旧 IP |
| crontab 定时 | Docker 容器内置定时循环 |
| jq 旧下载地址 / 数组索引 bug | 修复解析与健壮性问题（失败跳过、超时保护、无临时文件残留） |

## 工作流程

```
每 N 分钟（默认 10）→ TCP 探测实例静态 IP 的指定端口
  ├─ 端口可达 → IP 正常，本轮结束
  └─ 连续 FAIL_THRESHOLD 次失败 → 判定被墙
        → Lightsail: 释放旧静态 IP → 申请新静态 IP → 绑定回实例
        → Cloudflare: 更新 A 记录指向新 IP（CF_ENABLED=1 时）
        → Telegram: 推送区域/实例/旧IP/新IP/DNS状态
```

## 快速开始

### 1. 准备 AWS 凭证

创建一个仅含 Lightsail 权限的 IAM 用户（**不要用主账号 AK**），最小权限策略：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lightsail:GetStaticIps",
        "lightsail:GetInstance",
        "lightsail:ReleaseStaticIp",
        "lightsail:AllocateStaticIp",
        "lightsail:AttachStaticIp"
      ],
      "Resource": "*"
    }
  ]
}
```

### 2. 配置

```bash
cp .env.example .env
vim .env   # 填入 AWS AK/SK、区域、探测端口、TG/CF 配置
```

**REGION**地区参考

| 地区                     | 地区码         |
| ------------------------ | -------------- |
| 美国东部（俄亥俄）       | us-east-2      |
| 美国东部（弗吉尼亚北部） | us-east-1      |
| 美国西部（俄勒冈）       | us-west-2      |
| 亚太地区（孟买）         | ap-south-1     |
| 亚太地区（首尔）         | ap-northeast-2 |
| 亚太地区（新加坡）       | ap-southeast-1 |
| 亚太地区（悉尼）         | ap-southeast-2 |
| 亚太地区 (东京)          | ap-northeast-1 |
| 加拿大（中部）           | ca-central-1   |
| 欧洲（法兰克福）         | eu-central-1   |
| 欧洲 (爱尔兰)            | eu-west-1      |
| 欧洲（伦敦）             | eu-west-2      |
| 欧洲（巴黎）             | eu-west-3      |

### 3. 启动

**方式一：docker compose（推荐）**

```bash
docker compose up -d
docker logs -f lightsail-ip-changer
```

**方式二：docker run**

```bash
docker run -d --name lightsail-ip-changer --restart unless-stopped \
  -e REGION=ap-northeast-1 \
  -e AWS_ACCESS_KEY_ID=你的AK \
  -e AWS_SECRET_ACCESS_KEY=你的SK \
  -e CHECK_PORT=443 \
  -e CHECK_INTERVAL_MINUTES=10 \
  -e TG_NOTIFY=1 \
  -e TG_BOT_TOKEN=你的BOT_TOKEN \
  -e TG_CHAT_ID=你的CHAT_ID \
  -e CF_ENABLED=1 \
  -e CF_API_TOKEN=你的CF_API_TOKEN \
  -e CF_ZONE_ID=你的ZONE_ID \
  -e CF_RECORD_NAME=record.example.com \
  xiao6666/change-lightsail-ip:latest
```

> 不需要 Cloudflare 更新时去掉 `CF_*` 相关参数；不需要 TG 通知时把 `TG_NOTIFY` 改为 `0`；
> 单次模式（检测完退出）把 `CHECK_INTERVAL_MINUTES` 设为 `0`。

### 4. 手动触发一次完整检测

```bash
docker exec lightsail-ip-changer /app/change-lightsail-ip.sh ap-northeast-1 443
```

命令行参数优先于环境变量，因此也可以用一个肯定不通的端口来**手动复现"被墙"场景**做全链路测试：

```bash
docker exec lightsail-ip-changer /app/change-lightsail-ip.sh ap-northeast-1 9999
```

## 环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `REGION` | ✅ | - | Lightsail 区域，如 `ap-northeast-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | ✅* | - | AWS 凭证（*或挂载 `~/.aws` 目录） |
| `CHECK_PORT` | ❌ | 443 | TCP 探测端口（填你服务实际监听的端口） |
| `CHECK_INTERVAL_MINUTES` | ❌ | 10 | 检测间隔（分钟），`0` = 单次模式 |
| `TCP_TIMEOUT` | ❌ | 8 | 单次 TCP 探测超时（秒） |
| `FAIL_THRESHOLD` | ❌ | 5 | 判定被墙前需要的连续失败次数 |
| `TG_NOTIFY` | ❌ | 1 | TG 通知开关 |
| `TG_BOT_TOKEN` | ❌ | - | Telegram Bot Token（@BotFather 创建） |
| `TG_CHAT_ID` | ❌ | - | Telegram Chat ID（@userinfobot 查询） |
| `CF_ENABLED` | ❌ | 0 | 换 IP 后自动更新 Cloudflare A 记录 |
| `CF_API_TOKEN` | ❌ | - | CF API Token（需 `Zone.DNS:Edit` 权限） |
| `CF_ZONE_ID` | ❌ | - | CF 域名的 Zone ID（Overview 页右下角） |
| `CF_RECORD_NAME` | ❌ | - | 要更新的 A 记录，如 `record.example.com` |

## 判墙灵敏度说明

被墙判定 = 连续 `FAIL_THRESHOLD`（默认 5）次 TCP 探测失败，每次探测超时 `TCP_TIMEOUT`（默认 8 秒），
单轮最坏耗时约 **90 秒**。

- **真被墙**：GFW 封锁是持续性丢包，无论超时多长都会失败 → 必然触发
- **网络抖动**：晚高峰丢包等瞬时故障通常在几秒内恢复 → 大概率被多次重试过滤，不会误判
- 如果你的出口网络质量很差，可以把 `TCP_TIMEOUT` 调到 10、`FAIL_THRESHOLD` 调到 6~8 进一步降低误判率

## Cloudflare 配置说明

1. **API Token**：CF 面板 → My Profile → API Tokens → Create Token → 使用 "Edit zone DNS" 模板，Zone Resources 限定到你的域名
2. **Zone ID**：CF 面板 → 你的域名 → Overview 页右下角
3. **A 记录必须保持灰云（DNS only）**：脚本强制写入 `proxied=false`。若开橙云（CDN 代理），域名解析出的是 Cloudflare 的 IP，被墙的也是 CF 的 IP，换 Lightsail IP 就失去意义了
4. A 记录已存在则 PUT 更新，不存在则 POST 自动创建

## 注意事项

- ⚠️ **容器必须部署在境内机器上**（家里电脑 / 国内 VPS / NAS 等）。被墙是"从墙内看"的结论，部署在海外服务器上探测永远通畅，检测完全失效
- Lightsail 实例必须挂载了**静态 IP（Static IP）**。实例自带的动态公网 IP 不受脚本管理；若还没有，先在控制台 Networking → Create static IP → Attach 到实例（绑定运行中实例的静态 IP 免费）
- 换 IP 是热操作（detach/attach），**不会重启实例**，实例上的服务不受影响，只是公网入口变了
- Telegram 通知未配置时静默跳过，不影响换 IP 主流程

## 致谢

- 原项目：[angelsky11/change-lightsail-ip](https://github.com/angelsky11/change-lightsail-ip)

## License

MIT
