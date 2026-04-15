#!/bin/bash
# Entrypoint script for Hermes Agent on Hugging Face Spaces

set -e

echo "🚀 Hermes Agent v0.9.0 - Hugging Face Spaces"
echo "=============================================="

# 检查必要的环境变量
if [ -z "$HF_DATASET_REPO" ]; then
    echo "⚠️  警告: HF_DATASET_REPO 未设置，数据将不会持久化到 Dataset"
    echo "   设置方式: export HF_DATASET_REPO=your-username/hermes-data"
fi

# 创建必要的目录
echo "📁 初始化目录结构..."
mkdir -p /data/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache,whatsapp/session}
mkdir -p /app/logs

# 从 Dataset 恢复数据（如果配置了）
if [ -n "$HF_DATASET_REPO" ]; then
    echo "📥 从 Dataset 恢复数据..."
    python -m src.data_sync restore || {
        echo "⚠️  数据恢复失败，使用空配置启动"
        echo "   首次运行时会创建新的配置文件"
    }
fi

# 检查并创建默认 config.yaml（如果没有）
CONFIG_FILE="/data/.hermes/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "📝 创建默认配置文件..."
    cat > "$CONFIG_FILE" << 'EOF'
model:
  provider: openrouter
  name: openrouter/free
  temperature: 0.7
  max_tokens: 4096

terminal:
  backend: local
  timeout: 300

display:
  skin: default
  show_tool_progress: true

agent:
  max_iterations: 50
  approval_mode: ask
EOF
    echo "   ✅ 已创建默认 config.yaml"
fi

# 如果环境变量设置了模型，更新 config.yaml
if [ -n "$OPENROUTER_MODEL" ]; then
    echo "   更新模型配置: $OPENROUTER_MODEL"
    
    # 检查 config.yaml 是否存在
    if [ -f "$CONFIG_FILE" ]; then
        echo "   找到 config.yaml，更新模型名称..."
        # 使用 sed 更新模型名称（处理 YAML 格式）
        sed -i "s/^  name: .*/  name: $OPENROUTER_MODEL/" "$CONFIG_FILE" 2>/dev/null || true
        
        # 验证更新是否成功
        if grep -q "name: $OPENROUTER_MODEL" "$CONFIG_FILE"; then
            echo "   ✅ 模型配置更新成功"
        else
            echo "   ⚠️ 模型配置可能未更新，当前内容："
            grep "name:" "$CONFIG_FILE" | head -1
        fi
    else
        echo "   创建新的 config.yaml..."
        cat > "$CONFIG_FILE" << EOF
model:
  provider: openrouter
  name: $OPENROUTER_MODEL
  temperature: 0.7
  max_tokens: 4096
EOF
        echo "   ✅ 已创建 config.yaml"
    fi
fi

# 如果设置了 Gemini API Key，切换到 Gemini 模型
if [ -n "$GEMINI_API_KEY" ]; then
    echo "   检测到 Gemini API Key，切换到 Gemini 模型..."
    GEMINI_MODEL_NAME="${GEMINI_MODEL:-gemini-2.5-flash}"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "   更新 config.yaml 为 Gemini 配置..."
        # 创建新的 config.yaml 使用 Gemini
        cat > "$CONFIG_FILE" << EOF
model:
  provider: gemini
  name: $GEMINI_MODEL_NAME
  temperature: 0.7
  max_tokens: 8192

# Gemini API 配置
env:
  GEMINI_API_KEY: ${GEMINI_API_KEY}
EOF
        echo "   ✅ Gemini 模型配置完成: $GEMINI_MODEL_NAME"
    else
        echo "   创建 Gemini config.yaml..."
        cat > "$CONFIG_FILE" << EOF
model:
  provider: gemini
  name: $GEMINI_MODEL_NAME
  temperature: 0.7
  max_tokens: 8192
EOF
        echo "   ✅ 已创建 Gemini config.yaml"
    fi
fi

# 方案3: 注入环境变量到 .env 文件（实时自动持久化）
echo "⚙️  注入环境变量配置..."
ENV_FILE="/data/.hermes/.env"

# 创建或更新 .env 文件
mkdir -p /data/.hermes

# 定义需要持久化的环境变量列表
PERSISTENT_VARS=(
    "OPENROUTER_API_KEY"
    "OPENROUTER_MODEL"
    "OPENROUTER_APP_NAME"
    "TELEGRAM_BOT_TOKEN"
    "DISCORD_BOT_TOKEN"
    "DISCORD_CLIENT_ID"
    "SLACK_BOT_TOKEN"
    "SLACK_SIGNING_SECRET"
    "WHATSAPP_BUSINESS_ID"
    "WHATSAPP_PHONE_NUMBER"
    "WHATSAPP_ACCESS_TOKEN"
    # 注意：HF_TOKEN 和 HF_DATASET_REPO 不写入 .env，避免 Dataset 备份敏感信息
)

# 写入环境变量到 .env 文件（如果它们存在）
> "$ENV_FILE"  # 清空或创建文件
for var in "${PERSISTENT_VARS[@]}"; do
    if [ -n "${!var}" ]; then
        echo "${var}=${!var}" >> "$ENV_FILE"
        echo "   ✓ ${var}=${!var:0:20}..."  # 显示前20个字符
    else
        echo "   ✗ ${var} is empty or not set"
    fi
done

# 调试：显示已写入的环境变量（隐藏敏感信息）
echo "   环境变量详情（已脱敏）："
while IFS='=' read -r key value; do
    if [[ "$key" == *"_API_KEY"* ]] || [[ "$key" == *"_TOKEN"* ]] || [[ "$key" == *"_SECRET"* ]]; then
        # 敏感字段只显示前8位
        masked_value="${value:0:8}..."
        echo "   $key=$masked_value"
    else
        echo "   $key=$value"
    fi
done < "$ENV_FILE"

# 标记自动注入（用于区分）
echo "# Auto-injected by entrypoint.sh" >> "$ENV_FILE"
echo "# Timestamp: $(date -Iseconds)" >> "$ENV_FILE"

echo "   ✅ 已写入 $(grep -c '=' "$ENV_FILE" | head -1) 个环境变量到 $ENV_FILE"

# 设置同步间隔为60秒（实时同步）
SYNC_INTERVAL=${SYNC_INTERVAL:-60}
echo "🔄 数据同步间隔: ${SYNC_INTERVAL}秒（实时模式）"

# 启动后台数据同步服务（守护进程模式）
echo "🔄 启动数据同步服务..."
python -m src.data_sync daemon &
SYNC_PID=$!
echo "   同步服务 PID: $SYNC_PID"

# 尝试重载配置（如果存在）
echo "🔄 检查配置重载..."
if [ -f /data/.hermes/config.yaml ]; then
    echo "   发现已有配置，尝试重载..."
    hermes config check 2>/dev/null || echo "   配置检查完成"
fi

# 启动消息网关（如果配置了平台）
echo "📡 检查并启动消息网关..."
if [ -n "$TELEGRAM_BOT_TOKEN" ] || [ -n "$DISCORD_BOT_TOKEN" ]; then
    echo "   检测到 Gateway 配置，启动网关..."
    # 使用 'run' 而不是 'start'，因为容器中没有 systemd
    hermes gateway run &
    GATEWAY_PID=$!
    echo "   网关服务 PID: $GATEWAY_PID"
    sleep 3
    # 检查网关进程是否还在运行
    if kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "   ✅ 网关启动成功"
    else
        echo "   ⚠️ 网关可能启动失败，请检查配置"
    fi
else
    echo "   未检测到 Gateway 配置（缺少 TELEGRAM_BOT_TOKEN 或 DISCORD_BOT_TOKEN）"
    echo "   跳过网关启动，仅运行 Web Dashboard"
fi

# 提示用户配置重载方式
echo ""
echo "💡 配置变更提示："
echo "   在 WebUI 中修改配置后，系统会自动备份到 Dataset"
echo "   配置将在下次 Space 重启时自动生效"
echo "   如需立即生效，请在 WebUI 中使用 /reload 命令或重启 Space"
echo ""

# 注册优雅关闭处理函数
cleanup() {
    echo ""
    echo "🛑 收到关闭信号，执行清理..."
    
    # 停止数据同步服务
    if kill -0 $SYNC_PID 2>/dev/null; then
        echo "   停止数据同步服务..."
        kill $SYNC_PID 2>/dev/null || true
        wait $SYNC_PID 2>/dev/null || true
    fi
    
    # 执行最终备份
    if [ -n "$HF_DATASET_REPO" ]; then
        echo "   执行最终数据备份..."
        python -m src.data_sync backup --force || echo "   备份失败"
    fi
    
    echo "👋 再见！"
    exit 0
}

trap cleanup SIGTERM SIGINT

echo ""
echo "🌐 启动 Hermes Web Dashboard..."
echo "   访问地址: http://localhost:7860"
echo "   健康检查: http://localhost:7860/health"
echo ""

# 启动 Hermes Web Dashboard
# 注意： Hermes v0.9.0 使用 'dashboard' 命令而非 'web' 命令
exec hermes dashboard --host 0.0.0.0 --port 7860 --no-open
