#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:?必须设置 REGION 环境变量, 例如 ap-northeast-1}"
CHECK_PORT="${CHECK_PORT:-443}"

if [ ! -f ~/.aws/credentials ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    echo "错误: 缺少 AWS 凭证。请挂载 ~/.aws 或设置 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY" >&2
    exit 1
fi

INTERVAL_MIN="${CHECK_INTERVAL_MINUTES:-10}"

run_once() {
    echo "[$(date '+%F %T')] 开始检测 region=${REGION} port=${CHECK_PORT}"
    /app/change-lightsail-ip.sh "${REGION}" "${CHECK_PORT}" || echo "本轮执行失败, 下轮重试"
}

if [ "${INTERVAL_MIN}" -le 0 ]; then
    run_once
    echo "单次模式完成, 容器退出"
else
    echo "定时模式: 每 ${INTERVAL_MIN} 分钟检测一次 (Ctrl+C 或 docker stop 退出)"
    while true; do
        run_once
        sleep "$(( INTERVAL_MIN * 60 ))"
    done
fi
