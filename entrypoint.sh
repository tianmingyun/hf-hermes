#!/bin/bash
# Entrypoint script for Hermes Agent on Hugging Face Spaces
# 基于 Hermes Agent 真实 config.yaml 格式（source: cli-config.yaml.example + hermes_cli/config.py）
#
# Hermes config.yaml 真实结构：
#   model:        主模型 (default, provider, base_url, api_key)
#   auxiliary:    辅助模型 (vision, web_extract, compression, etc.)
#   delegation:   子代理配置 (model, provider, base_url, api_key, max_iterations, reasoning_effort)

set -e

echo "🚀 Hermes Agent v0.9.0 - Hugging Face Spaces"
echo "=============================================="

# 检查必要的环境变量
if [ -z "$HF_DATASET_REPO" ]; then
    echo "⚠️  警告: HF_DATASET_REPO 未设置，数据将不会持久化到 Dataset"
fi

# 创建必要的目录
echo "📁 初始化目录结构..."
mkdir -p /data/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache,whatsapp/session}
mkdir -p /app/logs

# 跳过从 Dataset 恢复 config.yaml（由本脚本根据环境变量重新生成）
export SKIP_CONFIG_RESTORE=true

# 从 Dataset 恢复数据（如果配置了）
if [ -n "$HF_DATASET_REPO" ]; then
    echo "📥 从 Dataset 恢复数据..."
    python -m src.data_sync restore || {
        echo "⚠️  数据恢复失败，使用空配置启动"
    }
fi

# ==================== 模型配置系统 ====================
echo "🤖 配置模型系统..."

# ---- 供应商定义 ----
declare -A PROVIDER_MODELS=(
    ["nvidia"]="moonshotai/kimi-k2-thinking"
    ["siliconflow"]="Pro/moonshotai/Kimi-K2.5"
    ["openai"]="gpt-4o"
    ["anthropic"]="claude-3-5-sonnet-20241022"
    ["google"]="gemini-2.0-flash"
    ["gemini"]="gemini-2.5-flash"
    ["openrouter"]="meta-llama/llama-3.1-8b-instruct:free"
    ["longcat"]="LongCat-Flash-Thinking-2601"
)

declare -A PROVIDER_API_KEYS=(
    ["nvidia"]="NVIDIA_API_KEY"
    ["siliconflow"]="SILICONFLOW_API_KEY"
    ["openai"]="OPENAI_API_KEY"
    ["anthropic"]="ANTHROPIC_API_KEY"
    ["google"]="GOOGLE_API_KEY"
    ["gemini"]="GEMINI_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
    ["longcat"]="LONGCAT_API_KEY"
)

declare -A PROVIDER_BASE_URLS=(
    ["nvidia"]="https://integrate.api.nvidia.com/v1"
    ["siliconflow"]="https://api.siliconflow.cn/v1"
    ["openai"]="https://api.openai.com/v1"
    ["anthropic"]="https://api.anthropic.com/v1"
    ["google"]="https://generativelanguage.googleapis.com"
    ["gemini"]="https://generativelanguage.googleapis.com"
    ["openrouter"]="https://openrouter.ai/api/v1"
    ["longcat"]="https://api.longcat.chat/openai"
)

# ---- 检测主模型 ----
detect_main_model() {
    if [ -n "$MODEL_PROVIDER" ] && [ -n "$MODEL_NAME" ]; then
        echo "manual:$MODEL_PROVIDER:$MODEL_NAME"
        return
    fi
    for provider in nvidia siliconflow openai anthropic google openrouter longcat; do
        api_key_var="${PROVIDER_API_KEYS[$provider]}"
        if [ -n "${!api_key_var}" ]; then
            if [ -n "$MODEL_NAME" ]; then
                echo "auto:$provider:$MODEL_NAME"
            else
                echo "auto:$provider:${PROVIDER_MODELS[$provider]}"
            fi
            return
        fi
    done
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "auto:gemini:${PROVIDER_MODELS[gemini]}"
        return
    fi
    echo "default:nvidia:${PROVIDER_MODELS[nvidia]}"
}

# ---- 检测辅助模型 ----
detect_vision_model() {
    if [ -n "$VISION_MODEL" ]; then echo "$VISION_MODEL"; return; fi
    if [ -n "$GEMINI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then echo "google/gemini-2.5-flash"; return; fi
    echo ""
}

detect_aux_model() {
    if [ -n "$AUX_MODEL" ]; then echo "$AUX_MODEL"; return; fi
    if [ -n "$OPENROUTER_API_KEY" ]; then echo "google/gemini-3-flash-preview"; return; fi
    if [ -n "$GEMINI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then echo "google/gemini-2.0-flash"; return; fi
    echo ""
}

detect_delegation_model() {
    if [ -n "$DELEGATION_MODEL" ]; then echo "$DELEGATION_MODEL"; return; fi
    if [ -n "$SILICONFLOW_API_KEY" ]; then echo "Pro/moonshotai/Kimi-K2.5"; return; fi
    echo ""
}

# ---- 执行检测 ----
echo ""
echo "📋 模型配置检测："
echo "────────────────────────────────────────"

MAIN_DETECTED=$(detect_main_model)
IFS=':' read -r MAIN_MODE MAIN_PROVIDER MAIN_MODEL <<< "$MAIN_DETECTED"
echo "🎯 Main Model: $MAIN_PROVIDER/$MAIN_MODEL (模式: $MAIN_MODE)"

VISION_MODEL_VAL=$(detect_vision_model)
echo "👁️  Vision Model: ${VISION_MODEL_VAL:-auto-detect}"

AUX_MODEL_VAL=$(detect_aux_model)
echo "⚡ Aux Model: ${AUX_MODEL_VAL:-auto-detect}"

DELEGATION_MODEL_VAL=$(detect_delegation_model)
echo "💻 Delegation Model: ${DELEGATION_MODEL_VAL:-inherit-main}"

MAIN_BASE_URL="${PROVIDER_BASE_URLS[$MAIN_PROVIDER]}"
echo "   Base URL: $MAIN_BASE_URL"

echo "────────────────────────────────────────"

# ==================== 生成 config.yaml ====================
CONFIG_FILE="/data/.hermes/config.yaml"
echo "📝 生成 config.yaml (Hermes 真实格式)..."

# 推断辅助模型供应商
infer_provider() {
    local model_id="$1"
    if [[ "$model_id" == google/* ]]; then echo "google"
    elif [[ "$model_id" == openrouter/* ]]; then echo "openrouter"
    elif [[ "$model_id" == Pro/* ]]; then echo "siliconflow"
    else echo "$MAIN_PROVIDER"; fi
}

VISION_PROVIDER_VAL=$(infer_provider "$VISION_MODEL_VAL")
AUX_PROVIDER_VAL=$(infer_provider "$AUX_MODEL_VAL")
DELEGATION_PROVIDER_VAL=$(infer_provider "$DELEGATION_MODEL_VAL")

cat > "$CONFIG_FILE" << EOF
# Hermes Agent Configuration
# Generated by entrypoint.sh at $(date -Iseconds)

# 主模型配置
model:
  default: "$MAIN_MODEL"
  provider: "$MAIN_PROVIDER"
  base_url: "$MAIN_BASE_URL"

# 辅助模型配置 (per-task overrides)
auxiliary:
  vision:
    provider: "${VISION_PROVIDER_VAL:-auto}"
    model: "${VISION_MODEL_VAL}"
    timeout: 120
    download_timeout: 30
  web_extract:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 360
  compression:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 120
  title_generation:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 30
  session_search:
    provider: "auto"
    model: ""
    timeout: 30
  skills_hub:
    provider: "auto"
    model: ""
    timeout: 30
  approval:
    provider: "auto"
    model: ""
    timeout: 30
  mcp:
    provider: "auto"
    model: ""
    timeout: 30
  flush_memories:
    provider: "auto"
    model: ""
    timeout: 30

# 子代理 (Delegation) 配置
delegation:
  model: "${DELEGATION_MODEL_VAL}"
  provider: "${DELEGATION_PROVIDER_VAL}"
  max_iterations: 50
  reasoning_effort: "medium"

# 终端配置
terminal:
  backend: local
  timeout: 300
  shell: /bin/bash

# 显示配置
display:
  skin: default
  show_tool_progress: true
  show_resume: true
  spinner: dots

# Agent 配置
agent:
  max_iterations: 50
  approval_mode: ask
  dangerous_command_approval: ask
  gateway_timeout: 300

# 记忆配置
memory:
  enabled: true
  provider: local

# 压缩配置
compression:
  enabled: true
  threshold: 0.50

# 定时任务
cron:
  enabled: true
  tick_interval: 60
EOF

echo "   ✅ 配置文件已生成"

# ==================== 导出供应商 Base URL 环境变量 ====================
echo "🌐 设置供应商 Base URL 环境变量..."

# 导出各供应商的 base_url，确保 Hermes 在 config check 时能识别
if [ -n "$NVIDIA_API_KEY" ]; then
    export NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com/v1}"
fi
if [ -n "$SILICONFLOW_API_KEY" ]; then
    export SILICONFLOW_BASE_URL="${SILICONFLOW_BASE_URL:-https://api.siliconflow.cn/v1}"
fi
if [ -n "$GEMINI_API_KEY" ]; then
    export GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}"
fi
if [ -n "$OPENROUTER_API_KEY" ]; then
    export OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
fi
if [ -n "$LONGCAT_API_KEY" ]; then
    export LONGCAT_BASE_URL="${LONGCAT_BASE_URL:-https://api.longcat.chat/openai}"
fi

# 导出 HERMES_MODEL 环境变量（进程级覆盖，影响 cron 等调度任务的模型选择）
export HERMES_MODEL="$MAIN_MODEL"

echo "   ✅ Base URL 环境变量已设置"
echo "   ✅ HERMES_MODEL=$HERMES_MODEL (进程级模型覆盖)"

# ==================== 环境变量注入 ====================
echo "⚙️  注入环境变量到 .env..."
ENV_FILE="/data/.hermes/.env"
mkdir -p /data/.hermes

PERSISTENT_VARS=(
    "MODEL_PROVIDER" "MODEL_NAME" "HERMES_MODEL"
    "VISION_MODEL" "AUX_MODEL" "DELEGATION_MODEL"
    "NVIDIA_API_KEY" "NVIDIA_BASE_URL"
    "SILICONFLOW_API_KEY" "SILICONFLOW_BASE_URL"
    "OPENAI_API_KEY"
    "ANTHROPIC_API_KEY"
    "GOOGLE_API_KEY" "GEMINI_API_KEY" "GEMINI_BASE_URL"
    "OPENROUTER_API_KEY" "OPENROUTER_BASE_URL"
    "LONGCAT_API_KEY" "LONGCAT_BASE_URL"
    "TELEGRAM_BOT_TOKEN" "TELEGRAM_ALLOWED_USERS"
    "DISCORD_BOT_TOKEN" "DISCORD_CLIENT_ID"
    "SLACK_BOT_TOKEN" "SLACK_SIGNING_SECRET"
    "WHATSAPP_BUSINESS_ID" "WHATSAPP_PHONE_NUMBER" "WHATSAPP_ACCESS_TOKEN"
)

> "$ENV_FILE"
for var in "${PERSISTENT_VARS[@]}"; do
    if [ -n "${!var}" ]; then
        echo "${var}=${!var}" >> "$ENV_FILE"
    fi
done

echo "   ✅ 已写入 $(grep -c '=' "$ENV_FILE") 个环境变量"

# ==================== 启动服务 ====================
SYNC_INTERVAL=${SYNC_INTERVAL:-60}
echo "🔄 数据同步间隔: ${SYNC_INTERVAL}秒"

echo "🔄 启动数据同步服务..."
python -m src.data_sync daemon &
SYNC_PID=$!
echo "   同步服务 PID: $SYNC_PID"

echo "🔄 检查配置..."
hermes config check 2>/dev/null || echo "   配置检查完成"

# ==================== 强制设置模型（防止 Hermes 启动时覆盖） ====================
echo "🔒 强制写入模型配置（防止启动时被覆盖）..."
# 使用 hermes config set 确保模型设置正确写入 config.yaml
# 这一步很关键：Hermes 内部的 config bridge 可能在启动时自动检测 API Key
# 并重新配置 provider/model，导致我们设置的模型被覆盖
hermes config set model.default "$MAIN_MODEL" 2>/dev/null || {
    echo "   ⚠️ hermes config set 不可用，使用直接写入方式"
    # 备用方案：使用 yq 或 sed 直接修改 config.yaml 中的 model.default
    if command -v yq &>/dev/null; then
        yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
    fi
}
hermes config set model.provider "$MAIN_PROVIDER" 2>/dev/null || true
hermes config set model.base_url "$MAIN_BASE_URL" 2>/dev/null || true

# 验证 config.yaml 中模型是否正确
if command -v yq &>/dev/null; then
    ACTUAL_MODEL=$(yq '.model.default' "$CONFIG_FILE" 2>/dev/null)
    if [ "$ACTUAL_MODEL" != "$MAIN_MODEL" ]; then
        echo "   ⚠️ 模型被覆盖! 期望: $MAIN_MODEL, 实际: $ACTUAL_MODEL"
        echo "   🔄 重新写入模型配置..."
        yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
        yq -i ".model.provider = \"$MAIN_PROVIDER\"" "$CONFIG_FILE"
        yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
    fi
fi

echo "   ✅ 模型配置已锁定: $MAIN_PROVIDER/$MAIN_MODEL"

echo "📡 检查并启动消息网关..."
if [ -n "$TELEGRAM_BOT_TOKEN" ] || [ -n "$DISCORD_BOT_TOKEN" ]; then
    echo "   启动网关..."
    hermes gateway run &
    GATEWAY_PID=$!
    sleep 3
    if kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "   ✅ 网关启动成功"
    else
        echo "   ⚠️ 网关可能启动失败"
    fi
else
    echo "   未检测到 Gateway 配置，仅运行 Web Dashboard"
fi

echo ""
echo "💡 提示："
echo "   - 在 WebUI Config 页面可查看完整配置"
echo "   - Delegation 菜单可查看子代理模型"
echo "   - Auxiliary 菜单可查看 vision/辅助模型"
echo ""

# 优雅关闭
cleanup() {
    echo ""
    echo "🛑 执行清理..."
    if kill -0 $SYNC_PID 2>/dev/null; then
        kill $SYNC_PID 2>/dev/null || true
        wait $SYNC_PID 2>/dev/null || true
    fi
    if [ -n "$DASHBOARD_PID" ] && kill -0 $DASHBOARD_PID 2>/dev/null; then
        kill $DASHBOARD_PID 2>/dev/null || true
        wait $DASHBOARD_PID 2>/dev/null || true
    fi
    if [ -n "$HF_DATASET_REPO" ]; then
        python -m src.data_sync backup --force || echo "   备份失败"
    fi
    echo "👋 再见！"
    exit 0
}

trap cleanup SIGTERM SIGINT

echo "🌐 启动 Hermes Web Dashboard..."
echo "   访问地址: http://localhost:7860"
echo ""

# 启动 Dashboard（后台），等待初始化后再次确认模型配置
hermes dashboard --host 0.0.0.0 --port 7860 --no-open --insecure &
DASHBOARD_PID=$!

# 等待 Dashboard 初始化完成
echo "⏳ 等待 Dashboard 初始化..."
sleep 5

# 再次验证模型配置（Dashboard 启动可能触发 config bridge 修改）
if [ -f "$CONFIG_FILE" ]; then
    if command -v yq &>/dev/null; then
        ACTUAL_MODEL=$(yq '.model.default' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$ACTUAL_MODEL" ] && [ "$ACTUAL_MODEL" != "$MAIN_MODEL" ] && [ "$ACTUAL_MODEL" != "null" ]; then
            echo "   ⚠️ 检测到模型被 Dashboard 启动流程覆盖!"
            echo "   📋 期望: $MAIN_MODEL, 实际: $ACTUAL_MODEL"
            echo "   🔒 重新写入正确的模型配置..."
            yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
            yq -i ".model.provider = \"$MAIN_PROVIDER\"" "$CONFIG_FILE"
            yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
            echo "   ✅ 模型已修正: $MAIN_PROVIDER/$MAIN_MODEL"
        elif [ -z "$ACTUAL_MODEL" ] || [ "$ACTUAL_MODEL" = "null" ]; then
            echo "   ⚠️ 检测到模型字段为空! 重新写入..."
            yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
            yq -i ".model.provider = \"$MAIN_PROVIDER\"" "$CONFIG_FILE"
            yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
            echo "   ✅ 模型已修正: $MAIN_PROVIDER/$MAIN_MODEL"
        else
            echo "   ✅ 模型配置验证通过: $MAIN_PROVIDER/$MAIN_MODEL"
        fi
    else
        # 没有 yq，使用 sed 做局部修改（仅修改 model.default 行）
        if ! grep -q "default:.*$MAIN_MODEL" "$CONFIG_FILE" 2>/dev/null; then
            echo "   ⚠️ 模型可能不匹配，使用 sed 修正..."
            # 在 model: 块内替换 default 行
            sed -i "/^model:/,/^[^ ]/ s/^[[:space:]]*default:.*/  default: \"$MAIN_MODEL\"/" "$CONFIG_FILE" 2>/dev/null || \
            sed -i "s/default:.*/default: \"$MAIN_MODEL\"/" "$CONFIG_FILE" 2>/dev/null || \
            echo "   ⚠️ 无法修改 config.yaml，请手动检查"
        fi
    fi
fi

# 等待 Dashboard 进程
wait $DASHBOARD_PID
