FROM python:3.11-slim

LABEL maintainer="Hermes Agent Community"
LABEL version="0.10.0"
LABEL description="Hermes Agent v0.10.0 with Web UI on Hugging Face Spaces"

# ==================== 环境变量 ====================
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV HERMES_HOME=/data/.hermes
ENV PYTHONPATH=/app

# BFF Server 环境变量（构建阶段）
ENV PORT=7860
ENV UPSTREAM=http://127.0.0.1:8642
ENV HERMES_BIN=/usr/local/bin/hermes
# 注意：NODE_ENV=production 不能在此设置！
# npm install 在 NODE_ENV=production 时会跳过 devDependencies，
# 导致 vue-tsc 等构建工具缺失。NODE_ENV 在运行时阶段再设置。

# ==================== 系统依赖 ====================
RUN apt-get update && apt-get install -y \
    build-essential \
    ffmpeg \
    git \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ==================== Node.js v23 ====================
# hermes-web-ui 要求 Node >= 23.0.0
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then NODE_ARCH="x64"; else NODE_ARCH="$ARCH"; fi \
    && echo "Installing Node.js v23.11.0 for ${NODE_ARCH}" \
    && curl -fsSL "https://nodejs.org/dist/v23.11.0/node-v23.11.0-linux-${NODE_ARCH}.tar.gz" \
       -o /tmp/node.tar.gz \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.gz \
    && node --version \
    && npm --version

# ==================== 工具安装 ====================
# yq: 运行时修改 config.yaml
RUN curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq && \
    chmod +x /usr/bin/yq

# ==================== Python 依赖 ====================
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ==================== Hermes Agent ====================
# 克隆并安装 Hermes Agent（不再构建内置 Dashboard 前端，由 hermes-web-ui 替代）
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent && \
    pip install --no-cache-dir /tmp/hermes-agent[all] && \
    rm -rf /tmp/hermes-agent /root/.cache/pip

# Playwright 浏览器（Hermes Agent 工具调用需要）
RUN npx playwright install chromium --with-deps --only-shell

# ==================== Hermes Web UI ====================
# 克隆、构建、精简 hermes-web-ui（单层，避免中间态占用空间）
RUN git clone --depth 1 https://github.com/EKKOLearnAI/hermes-web-ui.git /tmp/hermes-web-ui && \
    cd /tmp/hermes-web-ui && \
    npm pkg delete scripts.prepare && \
    npm install && \
    npm run build && \
    npm prune --omit=dev && \
    mkdir -p /opt/hermes-web-ui && \
    cp -r dist node_modules package.json /opt/hermes-web-ui/ && \
    rm -rf /tmp/hermes-web-ui /root/.npm

# ==================== 应用代码 ====================
WORKDIR /app

COPY src/ /app/src/
COPY entrypoint.sh /app/
COPY config/config.yaml /data/.hermes/config.yaml

# 创建数据目录
RUN mkdir -p /data/.hermes /data/.hermes-web-ui /app/logs && \
    chmod +x /app/entrypoint.sh

# 设置非 root 用户（Hugging Face Spaces 要求）
RUN useradd -m -u 1000 appuser && \
    ln -sf /data/.hermes /home/appuser/.hermes && \
    chown -R appuser:appuser /data /opt/hermes-web-ui /app

USER appuser

# ==================== 运行时环境变量 ====================
# 构建阶段不设 NODE_ENV=production（会导致 npm install 跳过 devDependencies）
# 此处设置，仅影响运行时行为
ENV NODE_ENV=production

# 7860: BFF Server (Web UI 入口，HF Spaces 要求)
# 8642: Gateway API Server (BFF 的上游代理目标，仅容器内部)
EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f http://localhost:7860/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
