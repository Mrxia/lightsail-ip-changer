#!/usr/bin/env bash
#
# 一键更换 Lightsail 被墙 IP（改良版）
# 原项目: https://github.com/angelsky11/change-lightsail-ip (2020)
# 改进:
#   1. TCP 端口探测替代 ping（更准确判断被墙）
#   2. Telegram Bot 通知替代 Server酱
#   3. 增加重试/超时保护, 无临时文件残留
#
# 依赖: aws cli (已配好 credentials), curl, jq
# 用法: ./change-lightsail-ip.sh YOUR_REGION [PORT]
#   YOUR_REGION 例: ap-northeast-1
#   PORT          可选, TCP 探测端口, 默认 443

# ===================== 配置区 =====================
# 所有配置优先从环境变量读取(Docker 部署用), 未设置时用默认值
TG_NOTIFY="${TG_NOTIFY:-1}"                       # Telegram 通知开关, 0=关闭 1=开启
TG_BOT_TOKEN="${TG_BOT_TOKEN:-YOUR_BOT_TOKEN}"    # 从 @BotFather 获取
TG_CHAT_ID="${TG_CHAT_ID:-YOUR_CHAT_ID}"          # 你的 chat_id, 可用 @userinfobot 查询

# 单次 TCP 连接超时(秒)
# 说明: 调大可降低"网络抖动被误判为被墙"的概率(GFW真墙时无论多久都超时)
TCP_TIMEOUT="${TCP_TIMEOUT:-8}"
# 判定"被墙"前需要的连续失败次数
# 说明: 单轮最坏耗时 = FAIL_THRESHOLD x (TCP_TIMEOUT x 2 + 2) 秒, 默认约90秒
FAIL_THRESHOLD="${FAIL_THRESHOLD:-5}"

# Cloudflare DNS 自动更新: 换IP成功后把新IP写入A记录
CF_ENABLED="${CF_ENABLED:-0}"            # 1=开启
CF_API_TOKEN="${CF_API_TOKEN:-}"         # API Token, 需 Zone.DNS Edit 权限
CF_ZONE_ID="${CF_ZONE_ID:-}"             # CF 面板域名 Overview 右侧的 Zone ID
CF_RECORD_NAME="${CF_RECORD_NAME:-}"     # 要更新的A记录, 如 subox.example.com
# ================================================

# 命令行参数优先于环境变量(方便 docker exec 手动指定端口测试被墙场景)
REGION="${1:-${REGION:-}}"
PORT="${2:-${CHECK_PORT:-443}}"

readonly TG_NOTIFY TG_BOT_TOKEN TG_CHAT_ID REGION PORT TCP_TIMEOUT FAIL_THRESHOLD \
    CF_ENABLED CF_API_TOKEN CF_ZONE_ID CF_RECORD_NAME

if [ -z "$REGION" ]; then
    echo "用法: $0 YOUR_REGION [PORT]  或通过环境变量 REGION/CHECK_PORT 配置"
    echo "  YOUR_REGION 例: ap-northeast-1 (东京) / ap-southeast-1 (新加坡) / us-west-2 (俄勒冈)"
    exit 1
fi

# ---------- 检查依赖 ----------
for cmd in aws curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少依赖: $cmd , 请先安装"
        exit 1
    fi
done

# ---------- Telegram 通知 ----------
tg_notify() {
    local text="$1"
    if [ "$TG_NOTIFY" != "1" ]; then return 0; fi
    local resp
    resp=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}")
    if echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        echo '[通知] Telegram 消息发送成功'
    else
        echo '[通知] Telegram 消息发送失败: '"$resp"
    fi
}

# ---------- Cloudflare DNS 更新 ----------
# 换IP成功后把新IP写入A记录, 存在则PUT更新, 不存在则POST新建
cf_update_dns() {
    local new_ip="$1"
    local api="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"

    if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_RECORD_NAME" ]; then
        echo '[DNS] Cloudflare 配置不完整(CF_API_TOKEN/CF_ZONE_ID/CF_RECORD_NAME), 跳过'
        return 1
    fi

    # 查找已存在的A记录
    local record_id
    record_id=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        "${api}?type=A&name=${CF_RECORD_NAME}" | jq -r '.result[0].id // empty')

    local resp ok
    if [ -n "$record_id" ]; then
        echo "[DNS] 更新A记录 ${CF_RECORD_NAME} -> ${new_ip}"
        resp=$(curl -s --max-time 10 -X PUT \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${api}/${record_id}" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${new_ip}\",\"ttl\":1,\"proxied\":false}")
    else
        echo "[DNS] A记录不存在, 新建 ${CF_RECORD_NAME} -> ${new_ip}"
        resp=$(curl -s --max-time 10 -X POST \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${api}" \
            --data "{\"type\":\"A\",\"name\":\"${CF_RECORD_NAME}\",\"content\":\"${new_ip}\",\"ttl\":1,\"proxied\":false}")
    fi

    ok=$(echo "$resp" | jq -r '.success // false')
    if [ "$ok" = "true" ]; then
        echo '[DNS] Cloudflare 记录更新成功'
        return 0
    fi
    echo "[DNS] Cloudflare 更新失败: ${resp}"
    return 1
}

# ---------- TCP 连通性探测 ----------
# 返回 0 = 端口可达, 返回 1 = 不可达
tcp_check() {
    local ip="$1"
    # -m 总超时(含TLS握手), --connect-timeout 仅TCP连接阶段; 两者都设避免卡死
    curl -s -o /dev/null --connect-timeout "$TCP_TIMEOUT" -m "$TCP_TIMEOUT" \
        "https://${ip}:${PORT}/" 2>/dev/null
    [ $? -eq 0 ] && return 0

    # https 握手失败但 TCP 可能是通的(非TLS服务), /dev/tcp 兜底
    # /dev/tcp 无内建超时, 被 GFW 丢包时会卡满内核超时(~2分钟), 用 timeout 强制限时
    timeout "$TCP_TIMEOUT" bash -c "exec 3<>/dev/tcp/${ip}/${PORT}" 2>/dev/null \
        && return 0
    return 1
}

# 连续 FAIL_THRESHOLD 次探测失败才算被墙
# 单轮最坏耗时: FAIL_THRESHOLD x (TCP_TIMEOUT x 2次探测 + 2s间隔)
# 默认: 3 x (5x2 + 2) = 36秒; 被墙时约36秒出结论, 不会卡几分钟
is_blocked() {
    local ip="$1" fails=0
    for (( i=0; i<FAIL_THRESHOLD; i++ )); do
        if tcp_check "$ip"; then
            return 1
        fi
        fails=$((fails+1))
        # 最后一轮不用再等
        [ "$i" -lt "$((FAIL_THRESHOLD-1))" ] && sleep 2
    done
    echo "[探测] ${ip} 连续 ${fails} 次 TCP:${PORT} 连接失败"
    return 0
}

# ---------- 主流程 ----------
main() {
    echo '***************************************************************'
    echo '********************* change-lightsail-ip *********************'
    echo "********************* region: ${REGION} port: ${PORT} ************"
    echo '***************************************************************'

    local ipjson
    ipjson=$(aws lightsail --region "$REGION" get-static-ips --output json) || {
        echo '[错误] 无法获取静态IP列表, 请检查 aws cli 配置和权限'
        exit 1
    }

    local NUM_IP
    NUM_IP=$(echo "$ipjson" | jq -r '.staticIps | length')

    if [ "$NUM_IP" -eq 0 ]; then
        echo '没有发现任何静态IP, 退出'
        exit 0
    fi
    echo "共发现 ${NUM_IP} 个静态IP"

    local i OLD_IP INSTANCE_NAME STATIC_IP_NAME NEW_IP
    for (( i=0; i<NUM_IP; i++ )); do
        OLD_IP=$(echo "$ipjson" | jq -r ".staticIps[${i}].ipAddress")
        INSTANCE_NAME=$(echo "$ipjson" | jq -r ".staticIps[${i}].attachedTo")
        STATIC_IP_NAME=$(echo "$ipjson" | jq -r ".staticIps[${i}].name")

        # Lightsail 新申请的静态IP可能还没绑定实例
        if [ "$INSTANCE_NAME" = "null" ] || [ -z "$INSTANCE_NAME" ]; then
            echo "----------------------------------------------------------------"
            echo "[跳过] 静态IP ${STATIC_IP_NAME}(${OLD_IP}) 未绑定实例, 不处理"
            continue
        fi

        echo "----------------------------------------------------------------"
        echo "[1] 检测实例 ${INSTANCE_NAME} 的 IP: ${OLD_IP} (TCP:${PORT})"

        if ! is_blocked "$OLD_IP"; then
            echo "[2] 该IP连通正常, 无需更换"
            continue
        fi

        echo "[2] 判定被墙, 开始更换IP..."
        echo "    - 释放旧静态IP ${STATIC_IP_NAME}"
        aws lightsail --region "$REGION" release-static-ip \
            --static-ip-name "$STATIC_IP_NAME" || { echo '[错误] 释放失败, 跳过'; continue; }

        sleep 3

        echo "    - 申请新静态IP ${STATIC_IP_NAME}"
        aws lightsail --region "$REGION" allocate-static-ip \
            --static-ip-name "$STATIC_IP_NAME" || { echo '[错误] 申请失败'; continue; }

        echo "    - 绑定到实例 ${INSTANCE_NAME}"
        aws lightsail --region "$REGION" attach-static-ip \
            --static-ip-name "$STATIC_IP_NAME" \
            --instance-name "$INSTANCE_NAME" || { echo '[错误] 绑定失败'; continue; }

        # 等待新IP生效
        sleep 10
        NEW_IP=$(aws lightsail --region "$REGION" get-instance \
            --instance-name "$INSTANCE_NAME" --output json \
            | jq -r '.instance.publicIpAddress')

        echo "[3] 更换完成: ${OLD_IP} -> ${NEW_IP}"

        local dns_status="未启用"
        if [ "$CF_ENABLED" = "1" ]; then
            if cf_update_dns "$NEW_IP"; then
                dns_status="已更新 ${CF_RECORD_NAME} -> ${NEW_IP}"
            else
                dns_status="更新失败, 请手动检查 Cloudflare"
            fi
        fi

        tg_notify "Lightsail IP 已更换

区域: ${REGION}
实例: ${INSTANCE_NAME}
旧IP: ${OLD_IP}
新IP: ${NEW_IP}
DNS: ${dns_status}"
    done

    echo '***************************************************************'
    echo '******************************* END ***************************'
    echo '***************************************************************'
}

main
exit 0
