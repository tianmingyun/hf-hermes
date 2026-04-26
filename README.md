4.26更新内容；

web UI 主要功能上手指南
现在你的 AI 助手已经部署好、微信也接通了，来看看 Web UI 还能做什么。
### 7.1 聊天（Chat）
点击左侧的 **Chat** 按钮，进入聊天界面。
- **新建对话**：点左上角的 **+ New Chat** 按钮
- **切换模型**：在聊天框上方的下拉菜单中切换不同的 AI 模型
- **搜索历史**：按 `Ctrl+K` 可以搜索所有历史对话
- **上传文件**：点击聊天框旁边的附件按钮，可以上传图片或文件让 AI 分析
- **下载文件**：AI 生成的文件可以在对话中直接下载
### 7.2 模型管理（Models）
点击左侧的 **Models** 按钮。
- 这里列出了你所有可用的 AI 模型供应商
- 点击任意供应商可以看到该供应商下有哪些模型
- 你可以添加新的供应商（支持任何 OpenAI 兼容的接口）
- **Nous Portal** 和 **OpenAI Codex** 还支持 OAuth 登录，直接在网页上点击授权就行
### 7.3 用量统计（Usage）
点击左侧的 **Usage** 按钮。
- 你可以看到 token 使用量的每日趋势图
- 每个模型的使用占比
- 估算的费用（基于公开的模型定价）
- 缓存命中率（缓存命中越多，速度越快、费用越低）
### 7.4 定时任务（Jobs）
点击左侧的 **Jobs** 按钮。
- 你可以创建定时任务，让 AI 在指定时间自动做事
- 比如每天早上 8 点总结新闻、每周一整理待办事项
- 支持 Cron 表达式（高级用户），也有简单的预设可选
- 可以随时暂停、恢复或手动触发执行
### 7.5 技能和记忆（Skills & Memory）
点击左侧对应的按钮。
- **Skills**：查看 AI 自己学到的技能。AI 会在使用过程中自动创建技能，比如"如何调用某个 API"或"用户喜欢的代码风格"
- **Memory**：查看和编辑 AI 关于你的记忆。你可以修改这些记忆来让 AI 更了解你
### 7.6 设置（Settings）
点击右上角的齿轮图标。
- **Display**：调整显示偏好（流式输出、紧凑模式等）
- **Agent**：AI 的行为参数（最大迭代次数、超时时间等）
- **Memory**：记忆系统的开关和限制
- **Session**：会话超时和重置设置
- **Privacy**：隐私保护（自动去除个人信息）




4.20更新了哪些内容

### 1. 备份恢复不再覆盖模型配置

**改动文件**：`src/data_sync.py`

之前的工作流程是：Space 启动 → 从 Dataset 恢复旧配置（覆盖新配置）→ 启动 Hermes。这导致每次重启后模型配置都被旧数据覆盖。

现在的流程是：Space 启动 → 从 Dataset 恢复其他数据（聊天记录、人格设定等）→ **跳过 config.yaml** → 由启动脚本根据当前环境变量重新生成配置。

具体来说，`data_sync.py` 的 `restore_from_download()` 方法现在会：
- 默认跳过 `config.yaml` 的恢复（由环境变量 `SKIP_CONFIG_RESTORE=true` 控制）
- 仅在本地完全不存在 config.yaml 时，才从备份中恢复一份作为初始值
- 其他数据（聊天记录、人格、技能等）照常恢复，不受影响

### 2. 三层防覆盖机制保护模型配置

**改动文件**：`entrypoint.sh`

即使跳过了旧配置恢复，Hermes 内部仍然有一个"配置桥接"机制，会在启动时自动检测 API Key 并可能修改 config.yaml。为了防止这种情况，我们增加了三层保护：

**第一层：环境变量注入**
- 在 Hermes 启动前，将所有供应商的 Base URL 导出到进程环境变量中
- 导出 `HERMES_MODEL` 环境变量，确保定时任务等场景也使用正确的模型
- 环境变量列表包括：`NVIDIA_BASE_URL`、`SILICONFLOW_BASE_URL`、`GEMINI_BASE_URL`、`OPENROUTER_BASE_URL`、`LONGCAT_BASE_URL`

**第二层：启动前强制锁定**
- 在 Dashboard 启动前，通过 `hermes config set` 命令将模型配置写入 config.yaml
- 如果 `hermes config set` 不可用，回退到 `yq` 工具直接修改 YAML 文件
- 修改后立刻用 `yq` 读取验证，确认模型字段没有被意外修改

**第三层：启动后二次验证**
- Dashboard 改为后台启动，等待 5 秒初始化
- 再次读取 config.yaml，检查模型配置是否被 Dashboard 启动流程覆盖
- 如果发现被修改或被清空，立即用 `yq` 修正回正确值
- 没有 `yq` 时回退到 `sed` 做局部修改（不会破坏其他配置项）

### 3. 修复压缩阈值错误

**改动文件**：`entrypoint.sh`、`config/config.yaml`

Hermes 的 `compression.threshold` 是一个**比率值**（0 到 1 之间的小数），不是绝对 token 数。例如 0.50 表示"当对话上下文使用到模型上下文窗口的 50% 时触发压缩"。

之前的配置写了 `threshold: 4000`，Hermes 把它当作"400000%"来计算，得出的压缩阈值为 8.19 亿 tokens，远超压缩模型 100 万 tokens 的处理能力，导致压缩功能完全失效。

现在改为 `threshold: 0.50`，含义清晰：对话上下文达到模型上限的 50% 时触发压缩，压缩模型 `gemini-3-flash-preview`（1M 上下文）完全能够处理。

### 4. Dockerfile 支持自动更新和 YAML 处理

**改动文件**：`Dockerfile`

- 移除了 `--branch v2026.4.13` 固定版本参数，改为始终拉取最新代码。这样在 Hugging Face Space 的 Settings 页面点击 **Factory Rebuild**，就会自动获取 Hermes Agent 的最新版本
- 新增安装 `yq`（YAML 处理工具），用于运行时精确修改 config.yaml 中的特定字段，而不是覆盖整个文件

### 5. 更新默认模型

**改动文件**：`entrypoint.sh`、`config/config.yaml`

NVIDIA 供应商的默认模型从 `minimaxai/minimax-m2.7`（该模型在实际使用中无响应）更换为 `moonshotai/kimi-k2-thinking`。




# Hermes Agent v0.9.0 on Hugging Face Spaces

智能AI代理，支持16个消息平台，持久化记忆，和Web管理界面。

## 功能

- 🤖 AI 对话与工具调用
- 🌐 Web Dashboard 管理
- 💾 数据持久化到 Hugging Face Dataset
- 🔔 支持消息网关（Telegram/Discord/Slack等）
- ⚡ 自动唤醒保持在线

## 技术栈

- Hermes Agent v0.9.0
- FastAPI Web Dashboard
- Hugging Face Datasets 持久化
- Docker Spaces

## 数据目录映射

| Hermes 目录 | Dataset 路径 | 说明 |
|------------|-------------|------|
| `~/.hermes/config.yaml` | `/config/config.yaml` | 核心配置 |
| `~/.hermes/.env` | `/config/.env` | 环境变量 |
| `~/.hermes/auth.json` | `/config/auth.json` | OAuth认证 |
| `~/.hermes/SOUL.md` | `/personality/SOUL.md` | 代理人格 |
| `~/.hermes/memories/` | `/memories/` | 持久记忆 |
| `~/.hermes/skills/` | `/skills/` | 自定义技能 |
| `~/.hermes/sessions/` | `/sessions/` | 会话历史 |
| `~/.hermes/state.db` | `/state/state.db` | SQLite数据库 |
| `~/.hermes/logs/` | `/logs/` | 日志文件 |
| `~/.hermes/cron/` | `/cron/` | 定时任务 |

## 环境变量

```bash
# 必需
HF_DATASET_REPO=your-username/hermes-data

# 可选
HERMES_HOME=/data/.hermes
SYNC_INTERVAL=300  # 同步间隔（秒）
HF_TOKEN=your-huggingface-token  # 用于访问私有 dataset
```

## 快速开始

### 1. 创建 Hugging Face Dataset

```bash
# 创建一个新的 dataset 用于存储数据
huggingface-cli repo create hermes-data --type dataset
```

### 2. 设置环境变量

在 Hugging Face Spaces 的 Settings 中设置：
- `HF_DATASET_REPO`: 你的 dataset 名称 (例如: username/hermes-data)
- `HF_TOKEN`: Hugging Face access token

### 3. 配置唤醒服务

使用 UptimeRobot 或 Cron-job.org 定期访问 Space URL 以保持在线。

## 部署步骤

### 部署到 Hugging Face Spaces

#### 方式一：通过 Web 界面部署

1. **创建 Space**: 访问 https://huggingface.co/new-space
   - 选择 "Docker" SDK
   - 设置 Space 名称
   - 选择硬件配置（免费版即可开始）

2. **克隆 Space 仓库**:
```bash
git clone https://huggingface.co/spaces/YOUR_USERNAME/YOUR_SPACE_NAME
cd YOUR_SPACE_NAME
```

3. **复制项目文件**:
```bash
# 复制所有项目文件到 Space 目录
cp -r /path/to/hermes-spaces/* .
```

4. **配置环境变量**:
   - 在 Space Settings → Variables 中设置:
     - `HF_DATASET_REPO`: `your-username/hermes-data`
     - `HF_TOKEN`: `your-huggingface-token`

5. **提交并推送**:
```bash
git add .
git commit -m "Initial deployment"
git push
```

6. **等待部署完成**:
   - 访问 `https://huggingface.co/spaces/YOUR_USERNAME/YOUR_SPACE_NAME`
   - 查看 Build 日志，等待部署完成

#### 方式二：通过 GitHub Actions 自动部署

1. **Fork 本仓库** 到你的 GitHub 账号

2. **在 Hugging Face 创建 Space**:
   - 访问 https://huggingface.co/new-space
   - 选择 Docker SDK
   - 记下 Space 名称

3. **配置 GitHub Secrets**:
   - 进入 GitHub 仓库 → Settings → Secrets and variables → Actions
   - 添加以下 secrets:
     - `HF_TOKEN`: 你的 Hugging Face access token
     - `HF_SPACE_REPO`: `YOUR_USERNAME/YOUR_SPACE_NAME`

4. **推送代码到 main 分支**:
```bash
git push origin main
```

5. **GitHub Actions 会自动部署**:
   - 查看 Actions 标签页查看部署进度
   - 部署完成后访问 Space URL

## 配置唤醒服务

由于 Hugging Face Spaces 免费版会在 48 小时无活动后休眠，建议配置外部唤醒服务：

### 使用 UptimeRobot（推荐）

1. 访问 https://uptimerobot.com 并注册账号
2. 点击 "Add New Monitor"
3. 配置如下：
   - **Monitor Type**: HTTP(s)
   - **Friendly Name**: Hermes Agent
   - **URL**: `https://YOUR_USERNAME-YOUR_SPACE_NAME.hf.space/health`
   - **Monitoring Interval**: 5 minutes
4. 点击 "Create Monitor"

### 使用 Cron-job.org（备选）

1. 访问 https://cron-job.org
2. 创建新的 cron job
3. 配置 URL: `https://YOUR_USERNAME-YOUR_SPACE_NAME.hf.space/health`
4. 设置每 5 分钟执行一次

## 首次使用

1. 访问 Space URL: `https://YOUR_USERNAME-YOUR_SPACE_NAME.hf.space`
2. 首次启动会创建默认配置，从 Dataset 恢复数据（如果存在）
3. 在 Web Dashboard 中配置：
   - API Keys（OpenAI, OpenRouter, etc.）
   - 消息网关（Telegram, Discord, etc.）
   - 代理人格（SOUL.md）

## 故障排除

### Space 无法启动

1. **检查构建日志**:
   - 访问 Space 页面 → Files → "Build logs"
   - 查看错误信息

2. **常见问题**:
   - **内存不足**: 升级到付费硬件（CPU Upgrade）
   - **依赖安装失败**: 检查 requirements.txt 格式
   - **权限错误**: 确保 Dockerfile 中设置了 USER appuser

### 数据未持久化

1. **检查环境变量**:
   - 确认 `HF_DATASET_REPO` 已正确设置
   - 确认 `HF_TOKEN` 有写入 Dataset 的权限

2. **检查 Dataset 权限**:
   - 确保 Dataset 是私有的（推荐）
   - 确保 Token 有 `write` 权限

3. **查看同步日志**:
   - 在 Space 的 Logs 中查看 data-sync 相关日志

### 消息网关断开

1. **这是正常现象**: Spaces 休眠后所有连接会断开
2. **解决方案**:
   - 升级到付费版保持持续运行
   - 或配置网关自动重连（在 Hermes 配置中设置）

## 文件说明

- `Dockerfile` - Docker 镜像定义
- `entrypoint.sh` - 容器启动脚本
- `requirements.txt` - Python 依赖
- `src/data_sync.py` - 数据同步服务
- `.github/workflows/deploy.yml` - GitHub Actions 自动部署

## 许可证

MIT License - 详见 LICENSE 文件

## 贡献

欢迎提交 Issue 和 Pull Request！

## 相关链接

- [Hermes Agent 官方仓库](https://github.com/NousResearch/hermes-agent)
- [Hugging Face Spaces 文档](https://huggingface.co/docs/hub/spaces-overview)
- [Hermes Agent 文档](https://hermes-agent.com)
