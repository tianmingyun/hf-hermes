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
