FROM python:3.11-slim

LABEL maintainer="Hermes Agent Community"
LABEL version="0.9.0"
LABEL description="Hermes Agent v0.9.0 on Hugging Face Spaces with persistent storage"

# 设置环境变量
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV HERMES_HOME=/data/.hermes
ENV PYTHONPATH=/app

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    build-essential \
    nodejs \
    npm \
    ffmpeg \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# 安装 Python 依赖
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# 克隆 Hermes Agent 仓库并本地构建前端
RUN git clone --depth 1 --branch v2026.4.13 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent && \
    cd /tmp/hermes-agent/web && \
    npm install && \
    npm run build

# 从本地路径安装 Hermes Agent [web] 包含 Dashboard 依赖
RUN pip install --no-cache-dir /tmp/hermes-agent[all,web]

# 安装 Playwright（使用精简版以减小镜像体积）
RUN npx playwright install chromium --with-deps --only-shell

# 创建应用目录
WORKDIR /app

# 复制应用代码
COPY src/ /app/src/
COPY entrypoint.sh /app/
COPY config/config.yaml /data/.hermes/config.yaml

# 创建数据目录
RUN mkdir -p /data/.hermes && \
    mkdir -p /app/logs && \
    chmod +x /app/entrypoint.sh

# 设置非 root 用户（Hugging Face Spaces 要求）
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /data && \
    chown -R appuser:appuser /app

USER appuser

# 暴露端口（Hugging Face Spaces 默认 7860）
EXPOSE 7860

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:7860/health || exit 1

# 启动脚本
ENTRYPOINT ["/app/entrypoint.sh"]
