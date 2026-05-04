#!/bin/bash
# Entrypoint script for Hermes Agent on Hugging Face Spaces
# 基于 Hermes Agent 真实 config.yaml 格式（source: cli-config.yaml.example + hermes_cli/config.py）
#
# 启动架构:
#   entrypoint.sh
#     ├── data_sync daemon (后台, 数据持久化)
#     ├── hermes gateway run (后台, API Server :8642 + 消息平台)
#     └── node /opt/hermes-web-ui/dist/server/index.js (前台, BFF :7860, 替代 hermes dashboard)

set -e

echo "🚀 Hermes Agent v0.10.0 - Hugging Face Spaces"
echo "=============================================="

# 确保 bun 在 PATH 中（baoyu-skills 子进程需要）
# bun 已安装在 /usr/local/bin（全局可访问），/home/appuser/.local/bin 用于 wrapper 脚本
export PATH="$PATH:/usr/local/bin:/home/appuser/.local/bin"

# 检查必要的环境变量
if [ -z "$HF_DATASET_REPO" ]; then
    echo "⚠️  警告: HF_DATASET_REPO 未设置，数据将不会持久化到 Dataset"
fi

# ==================== 初始化目录 ====================
echo "📁 初始化目录结构..."
mkdir -p /data/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache,whatsapp/session}
mkdir -p /data/.hermes-web-ui
mkdir -p /app/logs

echo "🔍 调试：初始化目录结构后检查"
pwd
ls -al /data/
ls -al /data/.hermes/
ls -al /data/.hermes/skills/

# ==================== 数据恢复 ====================
# 跳过从 Dataset 恢复 config.yaml（由本脚本根据环境变量重新生成）
export SKIP_CONFIG_RESTORE=true

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

# API Server 配置 (Web UI BFF 的上游代理目标)
api_server:
  enabled: true
  port: 8642
  host: "127.0.0.1"

# 终端配置
terminal:
  backend: local
  timeout: 300
  shell: /bin/bash
  # 允许 baoyu-skills 使用的 API Key 传递到子进程
  # (Hermes 默认会过滤包含 KEY/TOKEN/SECRET 的环境变量)
  env_passthrough:
    - GEMINI_API_KEY
    - GOOGLE_API_KEY
    - SILICONFLOW_API_KEY
    - GOOGLE_IMAGE_MODEL
    - GOOGLE_BASE_URL

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

# ==================== 合并用户配置（平台/channel 设置等） ====================
# 如果存在从 Dataset 恢复的 config.yaml.restored，将其中的用户修改区块合并到新生成的 config.yaml
# 合并策略：
#   - entrypoint.sh 控制的区块（model, auxiliary, delegation, api_server）：新生成的优先
#     （这些由 HF Spaces 环境变量决定，必须权威）
#   - 用户在 Web UI 中修改的区块（platforms, display, agent, memory, compression, cron, terminal）：
#     恢复的优先（保留用户的个性化设置，如 channel 行为、显示偏好等）
RESTORED_CONFIG="/data/.hermes/config.yaml.restored"
if [ -f "$RESTORED_CONFIG" ]; then
    echo "🔄 合并用户配置 (platforms, display, agent 等)..."
    python3 << 'MERGE_SCRIPT'
import yaml
import sys

GENERATED = '/data/.hermes/config.yaml'
RESTORED = '/data/.hermes/config.yaml.restored'

# 区块优先级定义：
# ENTRYPOINT_PRIORITY  → entrypoint.sh 生成的值优先（由 HF Spaces 环境变量控制）
# USER_PRIORITY        → 恢复的用户值优先（Web UI 中用户修改的偏好）
ENTRYPOINT_PRIORITY = {'model', 'auxiliary', 'delegation', 'api_server'}
USER_PRIORITY = {'platforms', 'display', 'agent', 'memory', 'compression', 'cron', 'terminal'}

try:
    with open(GENERATED) as f:
        generated = yaml.safe_load(f) or {}
    with open(RESTORED) as f:
        restored = yaml.safe_load(f) or {}

    merged = {}

    # 遍历所有出现在任一配置中的顶层键
    all_keys = set(list(generated.keys()) + list(restored.keys()))

    for key in all_keys:
        if key in ENTRYPOINT_PRIORITY:
            # 环境变量控制的区块：始终用新生成的值
            if key in generated:
                merged[key] = generated[key]
        elif key in USER_PRIORITY:
            # 用户偏好区块：优先用恢复的值，没有则用生成的默认值
            if key in restored:
                merged[key] = restored[key]
            elif key in generated:
                merged[key] = generated[key]
        else:
            # 未明确分类的区块：优先用恢复的值（保留用户可能做的修改）
            if key in restored:
                merged[key] = restored[key]
            elif key in generated:
                merged[key] = generated[key]

    with open(GENERATED, 'w') as f:
        yaml.dump(merged, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    # 统计合并了哪些区块
    merged_user_keys = [k for k in USER_PRIORITY if k in restored]
    merged_other_keys = [k for k in all_keys - ENTRYPOINT_PRIORITY - USER_PRIORITY if k in restored and k not in generated]
    print(f"   ✅ 已合并用户区块: {', '.join(merged_user_keys) if merged_user_keys else '无'}")

except Exception as e:
    print(f"   ⚠️ 合并配置失败: {e}，使用生成的默认配置")
    sys.exit(0)  # 不阻止启动
MERGE_SCRIPT
    # 合并完成后删除临时文件，避免被后续备份重复保存
    rm -f "$RESTORED_CONFIG"
else
    echo "   ℹ️ 无需合并（无恢复的用户配置）"
fi

# ==================== 导出供应商 Base URL 环境变量 ====================
echo "🌐 设置供应商 Base URL 环境变量..."

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

# 导出 API Server 环境变量（确保 Gateway 以 API Server 模式启动）
export API_SERVER_ENABLED=true
export API_SERVER_PORT=8642
export API_SERVER_HOST=127.0.0.1

# 默认允许所有用户（Hugging Face Spaces 单用户场景，否则 Gateway 拒绝所有消息）
export GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-true}"

# 导出 HERMES_MODEL 环境变量（进程级覆盖，影响 cron 等调度任务的模型选择）
export HERMES_MODEL="$MAIN_MODEL"

# 导出图像生成所需的环境变量（确保 baoyu-imagine 技能能检测到）
if [ -n "$SILICONFLOW_API_KEY" ]; then
    export SILICONFLOW_API_KEY
    export SILICONFLOW_BASE_URL="${SILICONFLOW_BASE_URL:-https://api.siliconflow.cn/v1}"
    echo "   ✅ SILICONFLOW_API_KEY 已导出（baoyu-imagine 技能可用）"
fi

if [ -n "$GEMINI_API_KEY" ]; then
    export GEMINI_API_KEY
    export GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}"
    # baoyu-imagine 的 google provider 使用 GOOGLE_API_KEY
    export GOOGLE_API_KEY="${GEMINI_API_KEY}"
    export GOOGLE_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}"
    export GOOGLE_IMAGE_MODEL="gemini-3.1-flash-image-preview"
    echo "   ✅ GEMINI_API_KEY 已导出（baoyu-imagine 技能可用）"
    echo "   ✅ GOOGLE_API_KEY 已设置（baoyu-imagine google provider）"
    echo "   ✅ GOOGLE_IMAGE_MODEL=gemini-3.1-flash-image-preview"
fi

echo "   ✅ Base URL 环境变量已设置"
echo "   ✅ API Server 环境变量已设置 (端口: 8642)"
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
    "API_SERVER_ENABLED" "API_SERVER_PORT" "API_SERVER_HOST"
    "TELEGRAM_BOT_TOKEN" "TELEGRAM_ALLOWED_USERS" "TELEGRAM_PROXY"
    "DISCORD_BOT_TOKEN" "DISCORD_CLIENT_ID"
    "SLACK_BOT_TOKEN" "SLACK_APP_TOKEN" "SLACK_SIGNING_SECRET"
    "WHATSAPP_BUSINESS_ID" "WHATSAPP_PHONE_NUMBER" "WHATSAPP_ACCESS_TOKEN"
    "WEIXIN_ACCOUNT_ID" "WEIXIN_TOKEN" "WEIXIN_BASE_URL"
    "GATEWAY_ALLOW_ALL_USERS"
    "AUTH_TOKEN"
)

# 合并策略：保留恢复的 .env 中由 BFF 等写入的变量（如 WEIXIN_ACCOUNT_ID/WEIXIN_TOKEN），
# 同时用进程环境变量覆盖同名键（进程环境变量优先级更高）。
# 这避免了 "先恢复再清空" 导致 BFF 写入的凭据丢失的问题。

# 第1步：读取恢复的 .env 中所有现有键值对（跳过注释和空行）
declare -A env_entries=()
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # 提取 KEY=VALUE
        eq_idx="${line%%=*}"
        if [ -n "$eq_idx" ] && [ "$eq_idx" != "$line" ]; then
            env_entries["$eq_idx"]="$line"
        fi
    done < "$ENV_FILE"
fi

# 第2步：用进程环境变量覆盖/新增 PERSISTENT_VARS 中的键
for var in "${PERSISTENT_VARS[@]}"; do
    if [ -n "${!var}" ]; then
        env_entries["$var"]="${var}=${!var}"
    else
        # 进程环境中没有该变量，但恢复的 .env 中可能有 → 保留恢复的值
        # 如果恢复的 .env 中也没有，则不写入
        :
    fi
done

# 第3步：写入合并后的 .env
{
    for key in "${!env_entries[@]}"; do
        echo "${env_entries[$key]}"
    done
} | sort > "$ENV_FILE"

RESTORED_COUNT=$(grep -c '=' "$ENV_FILE")
echo "   ✅ 已写入 ${RESTORED_COUNT} 个环境变量（含恢复的持久化变量）"

# ==================== 配置 baoyu-skills 技能 (EXTEND.md) ====================
# baoyu-imagine / baoyu-cover-image / baoyu-article-illustrator 的 EXTEND.md
# 路径规范: $HOME/.baoyu-skills/<skill-name>/EXTEND.md
# (注意: .baoyu-skills 有连字符, 不是 .baoyu/skills)
# main.ts loadExtendConfig() 查找顺序: {cwd}/.baoyu-skills/ > $XDG_CONFIG_HOME > $HOME/.baoyu-skills/
BAOYU_SKILLS_BASE="/home/appuser/.baoyu-skills"

# --- baoyu-imagine (图像生成后端) ---
IMAGINE_EXTEND_DIR="${BAOYU_SKILLS_BASE}/baoyu-imagine"
IMAGINE_EXTEND_FILE="${IMAGINE_EXTEND_DIR}/EXTEND.md"

if [ -n "$SILICONFLOW_API_KEY" ] || [ -n "$GEMINI_API_KEY" ]; then
    echo "⚙️  配置 baoyu-imagine 技能..."
    mkdir -p "${IMAGINE_EXTEND_DIR}"
    
    if [ -n "$GEMINI_API_KEY" ]; then
        # Gemini 作为主供应商（图像质量更好）
        # SiliconFlow 作为备用（在 wrapper 脚本中实现 fallback）
        cat > "${IMAGINE_EXTEND_FILE}" << EOF_IMAGINE
# Baoyu Imagine Configuration

# 默认供应商 (Google/Gemini)
default_provider = "google"

# 默认质量
default_quality = "2k"

# 默认宽高比
default_aspect_ratio = "16:9"

# 默认图片尺寸 (Google 使用 1K/2K/4K)
default_image_size = "2K"

# Google/Gemini 供应商配置
[default_model.google]
provider = "google"
model = "gemini-3.1-flash-image-preview"

# 批量设置
[batch]
max_workers = 4
EOF_IMAGINE
        echo "   ✅ baoyu-imagine EXTEND.md 已写入 (Gemini 主供应商)"
        
        # 同时导出 SiliconFlow 配置到 EXTEND.md（备用）
        if [ -n "$SILICONFLOW_API_KEY" ]; then
            echo "   🔄 SiliconFlow 已配置为备用供应商"
        fi
    elif [ -n "$SILICONFLOW_API_KEY" ]; then
        # 仅 SiliconFlow
        cat > "${IMAGINE_EXTEND_FILE}" << EOF_IMAGINE
# Baoyu Imagine Configuration

# 默认供应商
default_provider = "siliconflow"

# 默认质量
default_quality = "2k"

# 默认宽高比
default_aspect_ratio = "16:9"

# 默认图片尺寸
default_image_size = "1024x1024"

# SiliconFlow 供应商配置
[default_model.siliconflow]
provider = "siliconflow"
model = "Kwai-Kolors/Kolors"

# 批量设置
[batch]
max_workers = 4
EOF_IMAGINE
        echo "   ✅ baoyu-imagine EXTEND.md 已写入 (SiliconFlow 后端)"
    fi
    
    # 生成 ~/.baoyu-skills/.env 文件（绕过 Hermes 环境变量过滤）
    # Hermes 的 terminal 子进程会过滤包含 KEY/TOKEN/SECRET 的环境变量
    # baoyu-imagine 的 main.ts 会自动加载 ~/.baoyu-skills/.env
    BAOYU_ENV_FILE="${BAOYU_SKILLS_BASE}/.env"
    echo "   📝 生成 baoyu-skills .env 文件..."
    > "${BAOYU_ENV_FILE}"
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "GEMINI_API_KEY=${GEMINI_API_KEY}" >> "${BAOYU_ENV_FILE}"
        echo "GOOGLE_API_KEY=${GEMINI_API_KEY}" >> "${BAOYU_ENV_FILE}"
        echo "GOOGLE_IMAGE_MODEL=gemini-3.1-flash-image-preview" >> "${BAOYU_ENV_FILE}"
        echo "GOOGLE_BASE_URL=${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}" >> "${BAOYU_ENV_FILE}"
    fi
    if [ -n "$SILICONFLOW_API_KEY" ]; then
        echo "SILICONFLOW_API_KEY=${SILICONFLOW_API_KEY}" >> "${BAOYU_ENV_FILE}"
    fi
    echo "   ✅ .env 文件已写入 (${BAOYU_ENV_FILE})"
else
    echo "   ℹ️ 未配置 SILICONFLOW_API_KEY 或 GEMINI_API_KEY，跳过 baoyu-imagine 技能配置"
fi

# --- baoyu-cover-image (封面图生成) ---
COVER_EXTEND_DIR="${BAOYU_SKILLS_BASE}/baoyu-cover-image"
COVER_EXTEND_FILE="${COVER_EXTEND_DIR}/EXTEND.md"

if [ -n "$SILICONFLOW_API_KEY" ] || [ -n "$GEMINI_API_KEY" ]; then
    echo "⚙️  配置 baoyu-cover-image 技能..."
    mkdir -p "${COVER_EXTEND_DIR}"
    cat > "${COVER_EXTEND_FILE}" << EOF_COVER
# Baoyu Cover Image Configuration

# 首选图像后端
preferred_image_backend = "baoyu-imagine"

# 默认输出目录 (图片保存到哪里)
# independent = cover-image/{topic-slug}/
# imgs-subdir = {article-dir}/imgs/
# same-dir = {article-dir}/
# 使用 independent，图片会保存到 /data/cover-image/{topic-slug}/
# image-proxy.js 已配置扫描此目录
default_output_dir = "independent"

# 默认宽高比
default_aspect = "16:9"

# 默认类型与风格
preferred_type = "scene"
preferred_palette = "warm"
preferred_rendering = "digital"
preferred_font = "clean"

# 语言
language = "zh"
EOF_COVER
    echo "   ✅ baoyu-cover-image EXTEND.md 已写入 (${COVER_EXTEND_FILE})"
fi

# --- baoyu-article-illustrator (文章配图) ---
ILLUSTRATOR_EXTEND_DIR="${BAOYU_SKILLS_BASE}/baoyu-article-illustrator"
ILLUSTRATOR_EXTEND_FILE="${ILLUSTRATOR_EXTEND_DIR}/EXTEND.md"

if [ -n "$SILICONFLOW_API_KEY" ] || [ -n "$GEMINI_API_KEY" ]; then
    echo "⚙️  配置 baoyu-article-illustrator 技能..."
    mkdir -p "${ILLUSTRATOR_EXTEND_DIR}"
    cat > "${ILLUSTRATOR_EXTEND_FILE}" << EOF_ILLUSTRATOR
# Baoyu Article Illustrator Configuration

# 首选图像后端
preferred_image_backend = "baoyu-imagine"

# 默认输出目录
default_output_dir = "imgs-subdir"

# 默认类型与风格
preferred_type = "infographic"
preferred_style = "minimal-flat"
preferred_palette = "warm"

# 语言
language = "zh"
EOF_ILLUSTRATOR
    echo "   ✅ baoyu-article-illustrator EXTEND.md 已写入 (${ILLUSTRATOR_EXTEND_FILE})"
fi

# --- 调试: 验证 EXTEND.md 文件 ---
if [ -n "$SILICONFLOW_API_KEY" ] || [ -n "$GEMINI_API_KEY" ]; then
    echo "🔍 调试：验证 baoyu-skills EXTEND.md 文件"
    ls -la "${BAOYU_SKILLS_BASE}/" 2>/dev/null || echo "   ⚠️ ${BAOYU_SKILLS_BASE} 不存在"
    for skill_dir in "${BAOYU_SKILLS_BASE}"/*/; do
        if [ -f "${skill_dir}EXTEND.md" ]; then
            echo "   ✅ ${skill_dir}EXTEND.md 存在"
            # 显示 provider 配置（用于诊断）
            grep -E "^(default_provider|preferred_image_backend)" "${skill_dir}EXTEND.md" 2>/dev/null || true
        else
            echo "   ⚠️ ${skill_dir}EXTEND.md 缺失"
        fi
    done
fi

# ==================== 修复 baoyu-imagine 技能脚本缺失问题 ====================
# Hermes Skills Hub 安装 baoyu-imagine 时只下载了 SKILL.md 和 references
# 缺少 scripts/ 目录和 package.json，导致 agent 无法调用 bun scripts/main.ts
# 修复方案：将 Dockerfile 构建时预置的完整脚本复制到 skills 目录
# 如果 Dockerfile 预置失败（网络/缓存问题），则运行时下载

SKILL_IMAGINE_DIR="/data/.hermes/skills/baoyu-imagine"
SKILL_IMAGINE_SCRIPTS="${SKILL_IMAGINE_DIR}/scripts"
BUILTIN_IMAGINE_SCRIPTS="${BAOYU_SKILLS_BASE}/baoyu-imagine/scripts"

# 调试：显示脚本源状态
echo "🔍 调试：检查 baoyu-imagine 脚本源..."
echo "   内置脚本路径: ${BUILTIN_IMAGINE_SCRIPTS}"
if [ -d "$BUILTIN_IMAGINE_SCRIPTS" ]; then
    echo "   ✅ 内置脚本目录存在"
    ls -la "${BUILTIN_IMAGINE_SCRIPTS}/" 2>/dev/null | head -5 || echo "   ⚠️ 无法列出内置脚本内容"
else
    echo "   ⚠️ 内置脚本目录不存在（Dockerfile 构建时可能下载失败）"
fi
echo "   目标脚本路径: ${SKILL_IMAGINE_SCRIPTS}"
if [ -f "${SKILL_IMAGINE_SCRIPTS}/main.ts" ]; then
    echo "   ✅ 目标脚本已存在"
else
    echo "   ⚠️ 目标脚本缺失"
fi

# 主修复逻辑
if [ -n "$GEMINI_API_KEY" ]; then
    echo "⚙️  修复 baoyu-imagine 技能脚本..."
    
    # 1. 确保 skills 目录存在
    mkdir -p "${SKILL_IMAGINE_DIR}"
    
    # 2. 获取脚本（强制使用最新原始版本）
    # 注意：Dataset 恢复可能包含旧版本（Pollinations/SiliconFlow 特化版）
    # 必须重新下载原始 baoyu-skills 脚本以确保配置系统正常工作
    # 先删除可能存在的只读旧版本（chmod 555 导致 cp -r 无法覆盖）
    if [ -d "$BUILTIN_IMAGINE_SCRIPTS" ] && [ -f "${BUILTIN_IMAGINE_SCRIPTS}/main.ts" ]; then
        echo "   📁 从内置目录复制 scripts/..."
        rm -rf "${SKILL_IMAGINE_DIR}/scripts" 2>/dev/null || true
        cp -r "${BUILTIN_IMAGINE_SCRIPTS}" "${SKILL_IMAGINE_DIR}/"
    else
        echo "   📥 内置脚本不可用，运行时下载..."
        # 强制重新下载，忽略 Dataset 恢复的旧版本
        rm -rf "${SKILL_IMAGINE_SCRIPTS}"
        mkdir -p "${SKILL_IMAGINE_SCRIPTS}"
        TEMP_SKILLS_DIR="/tmp/baoyu-skills-download"
        rm -rf "$TEMP_SKILLS_DIR"
        if git clone --depth 1 https://github.com/JimLiu/baoyu-skills.git "$TEMP_SKILLS_DIR" 2>/dev/null; then
            if [ -f "${TEMP_SKILLS_DIR}/skills/baoyu-imagine/scripts/main.ts" ]; then
                cp -r "${TEMP_SKILLS_DIR}/skills/baoyu-imagine/scripts/" "${SKILL_IMAGINE_DIR}/"
                echo "   ✅ 运行时下载成功（原始完整版本）"
            else
                echo "   ❌ 下载的仓库中找不到 main.ts"
            fi
            rm -rf "$TEMP_SKILLS_DIR"
        else
            echo "   ❌ git clone 失败，请检查网络连接"
            echo "   ⚠️  使用现有脚本（可能不是原始版本）"
        fi
    fi
    
    # 3. 创建 package.json（如果不存在）
    if [ ! -f "${SKILL_IMAGINE_DIR}/package.json" ]; then
        echo "   📝 创建 package.json..."
        cat > "${SKILL_IMAGINE_DIR}/package.json" << 'EOF_PKG'
{
  "name": "baoyu-imagine",
  "version": "1.58.0",
  "type": "module",
  "scripts": {
    "build": "tsc",
    "test": "bun test"
  },
  "dependencies": {
    "@google/generative-ai": "^0.24.0"
  },
  "devDependencies": {
    "typescript": "^5.8.0",
    "@types/node": "^22.14.0"
  }
}
EOF_PKG
    fi
    
    # 4. 修复 google.ts 的 generateWithGemini 和 extractInlineImageData 函数
    # 修复1: responseModalities 从 ["IMAGE"] 改为 ["TEXT", "IMAGE"]
    # 修复2: extractInlineImageData 支持 inline_data 字段（snake_case）
    echo "   🔧 修复 google.ts 以支持 Google API 响应格式..."
    if [ -f "${SKILL_IMAGINE_DIR}/scripts/providers/google.ts" ]; then
        node -e "
            const fs = require('fs');
            const filePath = '${SKILL_IMAGINE_DIR}/scripts/providers/google.ts';
            let content = fs.readFileSync(filePath, 'utf8');
            let modified = false;
            
            // 修复1: responseModalities
            if (content.includes('responseModalities: [\"IMAGE\"],')) {
                content = content.replace(/responseModalities: \\[\"IMAGE\"\\],/g, 'responseModalities: [\"TEXT\", \"IMAGE\"],');
                console.log('   ✅ 已修复 responseModalities: [\"TEXT\", \"IMAGE\"]');
                modified = true;
            }
            
            // 修复2: extractInlineImageData 支持 inline_data 字段
            const oldLine = '      const data = part.inlineData?.data;';
            const newLine = '      const data = part.inlineData?.data ?? part.inline_data?.data;';
            if (content.includes(oldLine)) {
                content = content.replace(oldLine, newLine);
                console.log('   ✅ 已修复 extractInlineImageData 函数');
                modified = true;
            }
            
            if (modified) {
                fs.writeFileSync(filePath, content, 'utf8');
                console.log('   ✅ 所有修复应用完成');
            } else {
                console.log('   ⚠️  未找到需要修复的代码');
            }
        "
    fi
    
    # 5. 安装依赖（如果 node_modules 不存在）
    if [ ! -d "${SKILL_IMAGINE_DIR}/node_modules" ]; then
        echo "   📦 安装 baoyu-imagine 依赖..."
        (cd "${SKILL_IMAGINE_DIR}" && bun install) 2>&1 | tail -5 || {
            echo "   ⚠️  bun install 失败，尝试 npm install..."
            (cd "${SKILL_IMAGINE_DIR}" && npm install) 2>&1 | tail -5 || true
        }
    fi
    
    # 5. 最终验证（强检查）
    echo "   🔍 验证脚本完整性..."
    if [ -f "${SKILL_IMAGINE_SCRIPTS}/main.ts" ]; then
        echo "   ✅ baoyu-imagine 技能已就绪"
        echo "      脚本: ${SKILL_IMAGINE_SCRIPTS}/main.ts"
        ls -lh "${SKILL_IMAGINE_SCRIPTS}/main.ts"
        if [ -d "${SKILL_IMAGINE_DIR}/node_modules" ]; then
            echo "      依赖: 已安装 (${SKILL_IMAGINE_DIR}/node_modules)"
        else
            echo "      ⚠️ 依赖: 未安装"
        fi
    else
        echo "   ❌ baoyu-imagine 技能修复失败: main.ts 仍然缺失"
        echo "      这通常是因为网络问题导致无法下载脚本"
    fi
    
    # 6. 检测可用的图像生成后端并配置
    # 优先级: gemini > siliconflow
    # Gemini 图像质量更好，SiliconFlow 作为备用（国内稳定）
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "   🎯 检测到 GEMINI_API_KEY，启用 Gemini 主供应商..."
        echo "      模型: gemini-3.1-flash-image-preview"
        
        # 恢复原始 main.ts（支持 google provider）
        # 如果之前被 siliconflow 版本替换，从备份恢复
        if [ -f "${SKILL_IMAGINE_SCRIPTS}/main.ts.orig" ]; then
            cp "${SKILL_IMAGINE_SCRIPTS}/main.ts.orig" "${SKILL_IMAGINE_SCRIPTS}/main.ts"
            echo "   ✅ 已恢复原始 main.ts（支持 google provider）"
        fi
        
        # 创建智能包装脚本
        WRAPPER_DIR="/home/appuser/.local/bin"
        mkdir -p "$WRAPPER_DIR"
        
        if [ -n "$SILICONFLOW_API_KEY" ]; then
            # 双供应商：Gemini 主 + SiliconFlow 备
            # 使用双引号 heredoc 以展开 SKILL_IMAGINE_SCRIPTS 变量
            cat > "${WRAPPER_DIR}/baoyu-imagine" << EOF_WRAPPER
#!/bin/bash
# Smart wrapper: Gemini primary, SiliconFlow fallback

# 加载 baoyu-skills .env 文件（绕过 Hermes 环境变量过滤）
if [ -f ~/.baoyu-skills/.env ]; then
    set -a
    source ~/.baoyu-skills/.env
    set +a
fi

# 同时尝试从环境变量加载（如果未被过滤）
export GEMINI_API_KEY="\${GEMINI_API_KEY:-\$GEMINI_API_KEY}"
export GOOGLE_API_KEY="\${GOOGLE_API_KEY:-\$GEMINI_API_KEY}"
export GOOGLE_IMAGE_MODEL="\${GOOGLE_IMAGE_MODEL:-gemini-3.1-flash-image-preview}"
export GOOGLE_BASE_URL="\${GOOGLE_BASE_URL:-https://generativelanguage.googleapis.com}"
export SILICONFLOW_API_KEY="\${SILICONFLOW_API_KEY:-\$SILICONFLOW_API_KEY}"

# 确保图片保存到可访问的目录
mkdir -p /data/.hermes/image_cache
cd /data/.hermes/image_cache

# 尝试 Gemini 主供应商
# baoyu-imagine 的 google provider 会自动使用 GOOGLE_IMAGE_MODEL
echo "🎯 Trying Gemini (gemini-3.1-flash-image-preview)..."
if bun "${SKILL_IMAGINE_SCRIPTS}/main.ts" "\$@" 2>/tmp/gemini_error.log; then
    exit 0
fi

# Fallback 到 SiliconFlow
echo "⚠️  Gemini failed, falling back to SiliconFlow (Kwai-Kolors/Kolors)..."
if [ -f "/app/image-gen-siliconflow.ts" ]; then
    exec bun "/app/image-gen-siliconflow.ts" --model "Kwai-Kolors/Kolors" "\$@"
else
    echo "❌ SiliconFlow fallback script not found"
    cat /tmp/gemini_error.log >&2
    exit 1
fi
EOF_WRAPPER
            echo "   ✅ 智能包装脚本: ${WRAPPER_DIR}/baoyu-imagine (Gemini主 + SiliconFlow备)"
        else
            # 仅 Gemini
            cat > "${WRAPPER_DIR}/baoyu-imagine" << EOF_WRAPPER
#!/bin/bash
# Gemini-only wrapper

# 加载 baoyu-skills .env 文件（绕过 Hermes 环境变量过滤）
if [ -f ~/.baoyu-skills/.env ]; then
    set -a
    source ~/.baoyu-skills/.env
    set +a
fi

# 同时尝试从环境变量加载（如果未被过滤）
export GEMINI_API_KEY="\${GEMINI_API_KEY:-\$GEMINI_API_KEY}"
export GOOGLE_API_KEY="\${GOOGLE_API_KEY:-\$GEMINI_API_KEY}"
export GOOGLE_IMAGE_MODEL="\${GOOGLE_IMAGE_MODEL:-gemini-3.1-flash-image-preview}"
export GOOGLE_BASE_URL="\${GOOGLE_BASE_URL:-https://generativelanguage.googleapis.com}"

mkdir -p /data/.hermes/image_cache
cd /data/.hermes/image_cache

exec bun "${SKILL_IMAGINE_SCRIPTS}/main.ts" "\$@"
EOF_WRAPPER
            echo "   ✅ 包装脚本: ${WRAPPER_DIR}/baoyu-imagine (仅 Gemini)"
        fi
        chmod +x "${WRAPPER_DIR}/baoyu-imagine"
        
    elif [ -n "$SILICONFLOW_API_KEY" ]; then
        echo "   🎯 检测到 SILICONFLOW_API_KEY，启用 SiliconFlow 后端..."
        
        # 备份原始 main.ts
        if [ ! -f "${SKILL_IMAGINE_SCRIPTS}/main.ts.orig" ]; then
            cp "${SKILL_IMAGINE_SCRIPTS}/main.ts" "${SKILL_IMAGINE_SCRIPTS}/main.ts.orig"
        fi
        
        # 使用增强版 SiliconFlow 生成器（支持风格/尺寸/品质参数）
        ENHANCED_GEN="/app/image-gen-siliconflow.ts"
        if [ -f "$ENHANCED_GEN" ]; then
            cp "$ENHANCED_GEN" "${SKILL_IMAGINE_SCRIPTS}/main.ts"
            echo "   ✅ 已复制增强版生成器 (${ENHANCED_GEN})"
        else
            echo "   ⚠️ 增强版生成器不存在，使用内联简化版..."
            # 内联简化版作为 fallback
            cat > "${SKILL_IMAGINE_SCRIPTS}/main.ts" << 'EOF_SILICONFLOW'
#!/usr/bin/env bun
// Fallback simplified version
interface CliArgs { prompt: string; imagePath: string; model: string; }
function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = { prompt: "", imagePath: "", model: "black-forest-labs/FLUX.1-dev" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--prompt" || argv[i] === "-p") args.prompt = argv[++i] || "";
    else if (argv[i] === "--image") args.imagePath = argv[++i] || "";
    else if (argv[i] === "--model" || argv[i] === "-m") args.model = argv[++i] || args.model;
  }
  return args;
}
async function generateImage(args: CliArgs): Promise<void> {
  const apiKey = process.env.SILICONFLOW_API_KEY;
  if (!apiKey) { console.error("Error: SILICONFLOW_API_KEY not set"); process.exit(1); }
  console.log(`🎨 Generating image with ${args.model}...`);
  const response = await fetch("https://api.siliconflow.cn/v1/images/generations", {
    method: "POST", headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: args.model, prompt: args.prompt, image_size: "1024x1024", num_inference_steps: 20 })
  });
  if (!response.ok) { console.error(`❌ API error (${response.status})`); process.exit(1); }
  const result = await response.json();
  if (!result.images?.length) { console.error("❌ No images in response"); process.exit(1); }
  const imageUrl = result.images[0].url;
  const imageResponse = await fetch(imageUrl);
  const imageBuffer = await imageResponse.arrayBuffer();
  await Bun.write(args.imagePath, new Uint8Array(imageBuffer));
  console.log(`✅ Saved: ${args.imagePath} (${imageBuffer.byteLength} bytes)`);
}
const args = parseArgs(process.argv.slice(2));
if (!args.prompt || !args.imagePath) { console.error("Usage: bun main.ts --prompt <text> --image <path>"); process.exit(1); }
await generateImage(args);
EOF_SILICONFLOW
        fi
        
        echo "   ✅ 已配置 SiliconFlow 后端"
        echo "      模型: Kwai-Kolors/Kolors"
        echo "      API: https://api.siliconflow.cn/v1/images/generations"
        echo "      功能: --ar, --size, --quality, --n, --seed, --promptfiles"
        
        # 创建包装脚本（baoyu skills 调用 baoyu-imagine 命令）
        cat > "${WRAPPER_DIR}/baoyu-imagine" << EOF_WRAPPER
#!/bin/bash
# SiliconFlow wrapper

# 加载 baoyu-skills .env 文件（绕过 Hermes 环境变量过滤）
if [ -f ~/.baoyu-skills/.env ]; then
    set -a
    source ~/.baoyu-skills/.env
    set +a
fi

# 同时尝试从环境变量加载（如果未被过滤）
export SILICONFLOW_API_KEY="\${SILICONFLOW_API_KEY:-\$SILICONFLOW_API_KEY}"

# 确保图片保存到可访问的目录
mkdir -p /data/.hermes/image_cache
cd /data/.hermes/image_cache

exec bun "${SKILL_IMAGINE_SCRIPTS}/main.ts" "\$@"
EOF_WRAPPER
        chmod +x "${WRAPPER_DIR}/baoyu-imagine"
        echo "   ✅ 包装脚本: ${WRAPPER_DIR}/baoyu-imagine"
    else
        echo "   ⚠️ 未检测到 SILICONFLOW_API_KEY 或 GEMINI_API_KEY"
        echo "      图像生成功能不可用"
        echo "      请设置以下环境变量之一:"
        echo "        - GEMINI_API_KEY (推荐，图像质量更好)"
        echo "        - SILICONFLOW_API_KEY (国内可访问)"
    fi
    
    # 7. 设置文件权限（只读，防止 agent 意外修改）
    chmod -R 555 "${SKILL_IMAGINE_SCRIPTS}/" 2>/dev/null || true
    echo "   🔒 已锁定 scripts/ 目录"
    
    # 8. 创建 skills 目录下的 EXTEND.md 软链接
    # baoyu-imagine 会优先查找 skill 目录下的 EXTEND.md
    OLD_EXTEND="/data/.hermes/skills/baoyu-imagine/EXTEND.md"
    if [ -f "${IMAGINE_EXTEND_FILE}" ]; then
        mkdir -p "$(dirname "$OLD_EXTEND")"
        ln -sf "${IMAGINE_EXTEND_FILE}" "$OLD_EXTEND"
        echo "   🔗 创建 EXTEND.md 软链接: $OLD_EXTEND -> ${IMAGINE_EXTEND_FILE}"
    fi
fi

# ==================== 确保 image_cache 目录可写 ====================
mkdir -p /data/.hermes/image_cache
chmod 755 /data/.hermes/image_cache
chown appuser:appuser /data/.hermes/image_cache 2>/dev/null || true

# ==================== 启动数据同步服务 ====================
SYNC_INTERVAL=${SYNC_INTERVAL:-60}
echo "🔄 数据同步间隔: ${SYNC_INTERVAL}秒"

echo "🔄 启动数据同步服务..."
python -m src.data_sync daemon &
SYNC_PID=$!
echo "   同步服务 PID: $SYNC_PID"

# ==================== 配置检查 + 模型锁定 ====================
echo "🔄 检查配置..."
hermes config check 2>/dev/null || echo "   配置检查完成"

echo "🔒 强制写入模型配置（防止 Hermes 启动时被覆盖）..."
hermes config set model.default "$MAIN_MODEL" 2>/dev/null || {
    echo "   ⚠️ hermes config set 不可用，使用直接写入方式"
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

# ==================== 启动 Gateway (API Server + 消息平台) ====================
echo "📡 启动 Hermes Gateway + API Server..."

# Gateway PID 文件（用于追踪当前运行的 gateway 进程）
GATEWAY_PIDFILE="/data/.hermes/gateway.pid"

# Gateway 包装器：自动重启 + 崩溃恢复
# 使用 --replace 避免端口冲突（BFF 偶尔也通过 hermes-cli.ts 调用 restartGateway）
# 崩溃后等待 30 秒重启；正常退出不重启
# BFF 保存 weixin 凭据后会调用 restartGateway()，该函数在 Docker 模式下
# 会 kill 旧进程然后 spawn "hermes gateway run"，与本包装器可能竞争。
# --replace 让 gateway 在检测到端口占用时自动替换旧进程，避免冲突。
(
    while true; do
        hermes gateway run --replace 2>&1 | while IFS= read -r line; do
            echo "$line"
            case "$line" in
                *"Gateway failed to connect"*)
                    echo "   ⚠️ 网关消息平台连接失败，API Server 仍可使用，30 秒后重试..."
                    ;;
            esac
        done
        EXIT_CODE=${PIPESTATUS[0]}
        if [ "$EXIT_CODE" -ne 0 ]; then
            echo "   ⚠️ 网关进程退出 (code=$EXIT_CODE)，30 秒后重启..."
            sleep 30
        else
            echo "   🛑 网关正常退出（可能被 BFF restartGateway 替换）"
            # 检查是否有新 gateway 进程在运行（BFF 可能已启动新进程）
            sleep 5
            if [ -f "$GATEWAY_PIDFILE" ]; then
                NEW_PID=$(python3 -c "import json; print(json.load(open('$GATEWAY_PIDFILE')).get('pid',0))" 2>/dev/null || echo 0)
                if [ "$NEW_PID" -gt 0 ] && kill -0 "$NEW_PID" 2>/dev/null; then
                    echo "   🔄 检测到新网关进程 (PID: $NEW_PID)，等待其退出..."
                    # 等待新进程退出后再继续循环
                    while kill -0 "$NEW_PID" 2>/dev/null; do sleep 5; done
                    echo "   ⚠️ 新网关进程已退出，30 秒后重启包装器..."
                    sleep 30
                    continue
                fi
            fi
            echo "   🛑 无新网关进程，不再重启"
            break
        fi
    done
) &
GATEWAY_PID=$!

# 等待 API Server 就绪
echo "   ⏳ 等待 API Server 就绪 (:8642)..."
API_READY=false
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8642/health > /dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 1
done

if [ "$API_READY" = true ]; then
    echo "   ✅ API Server 已就绪 (http://127.0.0.1:8642)"
    # Gateway PID 文件由 Hermes 自己在 gateway run 启动时写入（gateway/run.py:write_pid_file）
    # 通过 symlink /home/appuser/.hermes → /data/.hermes，BFF GatewayManager 可正确读取
else
    echo "   ⚠️ API Server 未在 30 秒内就绪，继续启动 Web UI（API Server 可能稍后可用）"
fi

if kill -0 $GATEWAY_PID 2>/dev/null; then
    echo "   ✅ 网关进程运行中 (PID: $GATEWAY_PID)"
else
    echo "   ⚠️ 网关进程已退出，仅 Web UI 可用"
fi

echo ""
echo "💡 提示："
echo "   - Channels 页面可配置微信/飞书/企业微信等平台"
echo "   - Models 页面可管理模型供应商"
echo "   - Jobs 页面可管理定时任务"
echo ""

# ==================== Auth Token 处理 ====================
echo "🔑 配置 Web UI 认证..."
if [ -z "$AUTH_TOKEN" ]; then
    # 尝试从持久化文件恢复
    AUTH_TOKEN_FILE="/data/.hermes-web-ui/.token"
    if [ -f "$AUTH_TOKEN_FILE" ]; then
        AUTH_TOKEN=$(cat "$AUTH_TOKEN_FILE")
        echo "   ✅ 已恢复 Web UI 认证 Token"
    else
        # 自动生成新 Token
        AUTH_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)
        mkdir -p /data/.hermes-web-ui
        echo "$AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
        echo ""
        echo "   ╔══════════════════════════════════════════════════╗"
        echo "   ║  🔑 Web UI 认证 Token (请保存！)                 ║"
        echo "   ║  $AUTH_TOKEN"
        echo "   ║                                                    ║"
        echo "   ║  在 Web UI 登录页面输入此 Token                    ║"
        echo "   ║  也可在 HF Spaces Settings 设置 AUTH_TOKEN 覆盖   ║"
        echo "   ╚══════════════════════════════════════════════════╝"
        echo ""
    fi
else
    echo "   ✅ 使用环境变量中的 AUTH_TOKEN"
fi
export AUTH_TOKEN

# ==================== Web UI 自动更新 ====================
# Dockerfile 构建时安装的版本可能已过时
# 每次重启时检查并更新到最新版本

update_hermes_web_ui() {
    local WEBUI_DIR="/opt/hermes-web-ui"
    local TEMP_DIR="/tmp/hermes-web-ui-update"
    
    echo "🔄 检查 hermes-web-ui 更新..."
    
    # 获取远程最新版本
    local LATEST_VERSION
    LATEST_VERSION=$(curl -s https://api.github.com/repos/EKKOLearnAI/hermes-web-ui/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
    
    if [ -z "$LATEST_VERSION" ]; then
        echo "   ⚠️ 无法获取远程版本，跳过更新"
        return 0
    fi
    
    # 获取当前版本
    local CURRENT_VERSION="unknown"
    if [ -f "${WEBUI_DIR}/package.json" ]; then
        CURRENT_VERSION=$(cat "${WEBUI_DIR}/package.json" | grep '"version"' | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')
    fi
    
    echo "   当前版本: ${CURRENT_VERSION}"
    echo "   最新版本: ${LATEST_VERSION}"
    
    # 如果版本相同，跳过更新
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        echo "   ✅ 已是最新版本，跳过更新"
        return 0
    fi
    
    echo "   📥 检测到新版本，开始更新..."
    
    # 清理临时目录
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # 克隆最新代码
    if ! git clone --depth 1 https://github.com/EKKOLearnAI/hermes-web-ui.git "$TEMP_DIR"; then
        echo "   ❌ Git clone 失败，保留当前版本"
        rm -rf "$TEMP_DIR"
        return 0
    fi
    
    cd "$TEMP_DIR"
    
    # 获取克隆后的版本
    local CLONED_VERSION
    CLONED_VERSION=$(cat package.json | grep '"version"' | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')
    echo "   克隆版本: ${CLONED_VERSION}"
    
    # 如果克隆的版本和当前一样，跳过
    if [ "$CLONED_VERSION" = "$CURRENT_VERSION" ]; then
        echo "   ✅ 版本相同，跳过更新"
        cd /app
        rm -rf "$TEMP_DIR"
        return 0
    fi
    
    # 构建（需要 devDependencies）
    echo "   📦 安装依赖..."
    if ! npm install; then
        echo "   ❌ npm install 失败，保留当前版本"
        cd /app
        rm -rf "$TEMP_DIR"
        return 0
    fi
    
    echo "   🔨 构建..."
    if ! npm run build; then
        echo "   ❌ 构建失败，保留当前版本"
        cd /app
        rm -rf "$TEMP_DIR"
        return 0
    fi
    
    # 精简（移除 devDependencies）
    echo "   🧹 精简..."
    npm prune --omit=dev
    
    # 替换旧版本
    echo "   📝 替换旧版本..."
    rm -rf "${WEBUI_DIR}.bak" 2>/dev/null || true
    mv "$WEBUI_DIR" "${WEBUI_DIR}.bak" 2>/dev/null || true
    mkdir -p "$WEBUI_DIR"
    cp -r dist node_modules package.json "$WEBUI_DIR/"
    
    cd /app
    rm -rf "$TEMP_DIR" "${WEBUI_DIR}.bak"
    
    echo "   ✅ hermes-web-ui 已更新至 ${CLONED_VERSION}"
}

# 如果设置了 WEBUI_AUTO_UPDATE=true，则执行更新
if [ "${WEBUI_AUTO_UPDATE:-true}" = "true" ]; then
    update_hermes_web_ui
else
    echo "   ℹ️ Web UI 自动更新已禁用 (WEBUI_AUTO_UPDATE=false)"
fi

# ==================== 启动 Web UI (BFF Server + Image Proxy) ====================
# 架构: image-proxy.js (:7860) → BFF (:7861) → Gateway (:8642)
#
# image-proxy.js 在 :7860 监听:
#   /images/      → 图片文件浏览/下载 (来自 /data/.hermes/image_cache)
#   其他所有请求   → HTTP/WebSocket 透传给 BFF :7861
# BFF 在 :7861 内部监听 (hermes-web-ui)
echo "🌐 启动 Hermes Web UI..."
echo "   Image+Proxy: http://0.0.0.0:7860"
echo "   BFF Server:  http://127.0.0.1:7861"
echo "   Upstream:    http://127.0.0.1:8642"
echo "   📷 图片浏览: http://localhost:7860/images/"
echo ""

# 确保运行时环境变量设置完毕
export PORT=7861
export UPSTREAM=http://127.0.0.1:8642
export HERMES_BIN=/usr/local/bin/hermes
export HERMES_HOME=/data/.hermes

# 优雅关闭
cleanup() {
    echo ""
    echo "🛑 执行清理..."

    # 备份数据
    if [ -n "$HF_DATASET_REPO" ]; then
        echo "   💾 执行最终数据备份..."
        python -m src.data_sync backup --force 2>/dev/null || echo "   ⚠️ 备份失败"
    fi

    # 停止各进程（顺序：ImageProxy → BFF → Gateway → Sync）
    if [ -n "$PROXY_PID" ] && kill -0 $PROXY_PID 2>/dev/null; then
        echo "   🛑 停止 Image Proxy..."
        kill $PROXY_PID 2>/dev/null || true
        wait $PROXY_PID 2>/dev/null || true
    fi
    if [ -n "$BFF_PID" ] && kill -0 $BFF_PID 2>/dev/null; then
        echo "   🛑 停止 Web UI..."
        kill $BFF_PID 2>/dev/null || true
        wait $BFF_PID 2>/dev/null || true
    fi
    if [ -n "$GATEWAY_PID" ] && kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "   🛑 停止 Gateway..."
        kill $GATEWAY_PID 2>/dev/null || true
        wait $GATEWAY_PID 2>/dev/null || true
    fi
    if kill -0 $SYNC_PID 2>/dev/null; then
        echo "   🛑 停止数据同步..."
        kill $SYNC_PID 2>/dev/null || true
        wait $SYNC_PID 2>/dev/null || true
    fi

    echo "👋 再见！"
    exit 0
}

trap cleanup SIGTERM SIGINT

# 启动 BFF Server (内部端口 7861, 不对外暴露)
node /opt/hermes-web-ui/dist/server/index.js &
BFF_PID=$!

# 等待 BFF 就绪
echo "   ⏳ 等待 BFF 就绪 (:7861)..."
BFF_READY=false
for i in $(seq 1 20); do
    if curl -sf http://localhost:7861/health > /dev/null 2>&1; then
        BFF_READY=true
        break
    fi
    sleep 1
done

if [ "$BFF_READY" = true ]; then
    echo "   ✅ BFF 已就绪 → http://127.0.0.1:7861"
else
    echo "   ⚠️ BFF 未在 20 秒内就绪，请查看日志"
fi

# 启动 Image Proxy (对外端口 7860, HF Spaces 入口)
echo "🖼️  启动 Image Proxy..."
BFF_PORT=7861 LISTEN_PORT=7860 IMAGE_DIR=/data/.hermes/image_cache \
    node /app/image-proxy.js &
PROXY_PID=$!

# 等待 Image Proxy 就绪
PROXY_READY=false
for i in $(seq 1 10); do
    if curl -sf http://localhost:7860/health > /dev/null 2>&1; then
        PROXY_READY=true
        break
    fi
    sleep 1
done

if [ "$PROXY_READY" = true ]; then
    echo "   ✅ Web UI 已就绪 → http://localhost:7860"
    echo "   📷 图片浏览 → http://localhost:7860/images/"
else
    echo "   ⚠️ Image Proxy 未就绪，Web UI 可能不可用"
fi

# 再次验证模型配置（BFF 启动可能修改 config.yaml）
if [ -f "$CONFIG_FILE" ]; then
    if command -v yq &>/dev/null; then
        ACTUAL_MODEL=$(yq '.model.default' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$ACTUAL_MODEL" ] && [ "$ACTUAL_MODEL" != "$MAIN_MODEL" ] && [ "$ACTUAL_MODEL" != "null" ]; then
            echo "   ⚠️ 检测到模型被 BFF 启动流程覆盖!"
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
    fi
fi

# 等待 Image Proxy 主进程（前台阻塞，容器生命周期由 Proxy 控制）
# Proxy 退出通常意味着 BFF 也挂了
wait $PROXY_PID
