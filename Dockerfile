FROM debian:bookworm-slim

LABEL maintainer="lightsail-ip-changer"
LABEL description="Auto change blocked AWS Lightsail static IP, update Cloudflare DNS, notify via Telegram"

# 注意: AWS CLI v2 官方二进制基于 glibc, 无法直接跑在 Alpine(musl) 上,
# 因此基础镜像使用 Debian; TARGETARCH 由 BuildKit 自动注入(amd64/arm64)
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip jq bash \
    && rm -rf /var/lib/apt/lists/* \
    && if [ "$TARGETARCH" = "arm64" ]; then AWS_PKG="awscli-exe-linux-aarch64.zip"; \
       else AWS_PKG="awscli-exe-linux-x86_64.zip"; fi \
    && curl -fsSL "https://awscli.amazonaws.com/${AWS_PKG}" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin \
    && rm -rf /tmp/aws /tmp/awscliv2.zip \
    && aws --version && jq --version

WORKDIR /app

# 同时复制两个脚本(缺任何一个都会在这里报错, 方便定位)
COPY change-lightsail-ip.sh entrypoint.sh /app/
RUN chmod +x /app/*.sh && ls -la /app/

# 默认每10分钟检测一次, 设为 0 则只跑一次退出
ENV CHECK_INTERVAL_MINUTES=10

ENTRYPOINT ["/app/entrypoint.sh"]
