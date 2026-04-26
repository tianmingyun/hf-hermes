#!/usr/bin/env python3
"""
Hermes Agent Data Sync Service
Handles data persistence to/from Hugging Face Dataset
"""

import os
import sys
import time
import json
import shutil
import tarfile
import argparse
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, List

from huggingface_hub import HfApi, hf_hub_download, upload_folder
from loguru import logger

# 文件监控（可选）
try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    WATCHDOG_AVAILABLE = True
except ImportError:
    WATCHDOG_AVAILABLE = False
    logger.warning("watchdog not installed, file change detection disabled")


class DatasetManager:
    """Manages data synchronization with Hugging Face Dataset"""
    
    def __init__(self, dataset_repo: Optional[str] = None, token: Optional[str] = None):
        self.dataset_repo = dataset_repo or os.environ.get('HF_DATASET_REPO')
        self.token = token or os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
        self.api = HfApi(token=self.token)
        self.hermes_home = Path(os.environ.get('HERMES_HOME', '/data/.hermes'))
        self.temp_dir = Path('/tmp/hermes_sync')
        
        # 数据路径映射
        self.path_mapping = {
            'config': self.hermes_home / 'config.yaml',
            'env': self.hermes_home / '.env',
            'auth': self.hermes_home / 'auth.json',
            'soul': self.hermes_home / 'SOUL.md',
            'memories': self.hermes_home / 'memories',
            'skills': self.hermes_home / 'skills',
            'sessions': self.hermes_home / 'sessions',
            'state_db': self.hermes_home / 'state.db',
            'logs': self.hermes_home / 'logs',
            'cron': self.hermes_home / 'cron',
            'webui_token': Path('/data/.hermes-web-ui') / '.token',
        }
        
    def validate(self) -> bool:
        """验证配置是否正确"""
        if not self.dataset_repo:
            logger.error("HF_DATASET_REPO not set")
            return False
        
        if not self.token:
            logger.warning("HF_TOKEN not set, will try public dataset")
            
        return True
    
    def prepare_backup_data(self) -> Path:
        """准备备份数据到临时目录"""
        logger.info("Preparing backup data...")
        
        # 清理并创建临时目录
        if self.temp_dir.exists():
            shutil.rmtree(self.temp_dir)
        self.temp_dir.mkdir(parents=True)
        
        # 创建目录结构
        (self.temp_dir / 'config').mkdir()
        (self.temp_dir / 'personality').mkdir()
        (self.temp_dir / 'memories').mkdir()
        (self.temp_dir / 'skills').mkdir()
        (self.temp_dir / 'sessions').mkdir()
        (self.temp_dir / 'state').mkdir()
        (self.temp_dir / 'logs').mkdir()
        (self.temp_dir / 'cron').mkdir()
        (self.temp_dir / 'webui').mkdir()
        
        # 复制文件
        try:
            # 配置文件
            if self.path_mapping['config'].exists():
                shutil.copy2(self.path_mapping['config'], self.temp_dir / 'config' / 'config.yaml')
            
            # 环境变量（敏感信息）
            if self.path_mapping['env'].exists():
                shutil.copy2(self.path_mapping['env'], self.temp_dir / 'config' / '.env')
            
            # OAuth 认证
            if self.path_mapping['auth'].exists():
                shutil.copy2(self.path_mapping['auth'], self.temp_dir / 'config' / 'auth.json')
            
            # 人格定义
            if self.path_mapping['soul'].exists():
                shutil.copy2(self.path_mapping['soul'], self.temp_dir / 'personality' / 'SOUL.md')
            
            # 记忆
            if self.path_mapping['memories'].exists():
                shutil.copytree(self.path_mapping['memories'], self.temp_dir / 'memories', dirs_exist_ok=True)
            
            # 技能
            if self.path_mapping['skills'].exists():
                shutil.copytree(self.path_mapping['skills'], self.temp_dir / 'skills', dirs_exist_ok=True)
            
            # 会话
            if self.path_mapping['sessions'].exists():
                shutil.copytree(self.path_mapping['sessions'], self.temp_dir / 'sessions', dirs_exist_ok=True)
            
            # 数据库
            if self.path_mapping['state_db'].exists():
                shutil.copy2(self.path_mapping['state_db'], self.temp_dir / 'state' / 'state.db')
            
            # 日志
            if self.path_mapping['logs'].exists():
                shutil.copytree(self.path_mapping['logs'], self.temp_dir / 'logs', dirs_exist_ok=True)
            
            # 定时任务
            if self.path_mapping['cron'].exists():
                shutil.copytree(self.path_mapping['cron'], self.temp_dir / 'cron', dirs_exist_ok=True)
            
            # WebUI 认证 Token
            if self.path_mapping['webui_token'].exists():
                (self.temp_dir / 'webui').mkdir(exist_ok=True)
                shutil.copy2(self.path_mapping['webui_token'], self.temp_dir / 'webui' / '.token')
            
            # 添加元数据
            metadata = {
                'timestamp': datetime.now().isoformat(),
                'version': '0.10.0',
                'hermes_home': str(self.hermes_home)
            }
            with open(self.temp_dir / 'metadata.json', 'w') as f:
                json.dump(metadata, f, indent=2)
            
            logger.success(f"Backup prepared at {self.temp_dir}")
            return self.temp_dir
            
        except Exception as e:
            logger.error(f"Failed to prepare backup: {e}")
            raise
    
    def upload_to_dataset(self, force: bool = False) -> bool:
        """上传数据到 Hugging Face Dataset"""
        try:
            backup_dir = self.prepare_backup_data()
            
            logger.info(f"Uploading to dataset: {self.dataset_repo}")
            
            # 上传文件夹到 dataset
            self.api.upload_folder(
                folder_path=str(backup_dir),
                repo_id=self.dataset_repo,
                repo_type="dataset",
                commit_message=f"Hermes Agent backup - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
            )
            
            logger.success("Backup uploaded successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to upload to dataset: {e}")
            return False
    
    def download_from_dataset(self) -> bool:
        """从 Hugging Face Dataset 下载数据"""
        try:
            logger.info(f"Downloading from dataset: {self.dataset_repo}")
            
            # 创建临时下载目录
            download_dir = Path('/tmp/hermes_download')
            if download_dir.exists():
                shutil.rmtree(download_dir)
            download_dir.mkdir(parents=True)
            
            # 下载所有文件
            self.api.snapshot_download(
                repo_id=self.dataset_repo,
                repo_type="dataset",
                local_dir=str(download_dir)
            )
            
            logger.success("Download completed")
            
            # 恢复数据到 Hermes 目录
            self.restore_from_download(download_dir)
            return True
            
        except Exception as e:
            logger.error(f"Failed to download from dataset: {e}")
            return False
    
    def restore_from_download(self, download_dir: Path):
        """从下载的目录恢复数据
        
        注意: config.yaml 在恢复时被跳过，因为 entrypoint.sh 会根据环境变量
        重新生成正确的 config.yaml。如果恢复旧的 config.yaml，会导致模型
        配置被覆盖（例如 minimaxai/minimax-m2.7 被替换为旧模型）。
        """
        logger.info("Restoring data to Hermes home...")
        
        # 确保目标目录存在
        self.hermes_home.mkdir(parents=True, exist_ok=True)
        
        # 恢复各个部分（跳过 config.yaml，由 entrypoint.sh 重新生成）
        skip_restore = os.environ.get('SKIP_CONFIG_RESTORE', 'true').lower() in ('true', '1', 'yes')
        
        restore_mapping = {
            'config/.env': self.path_mapping['env'],
            'config/auth.json': self.path_mapping['auth'],
            'personality/SOUL.md': self.path_mapping['soul'],
            'memories': self.path_mapping['memories'],
            'skills': self.path_mapping['skills'],
            'sessions': self.path_mapping['sessions'],
            'state/state.db': self.path_mapping['state_db'],
            'logs': self.path_mapping['logs'],
            'cron': self.path_mapping['cron'],
            'webui/.token': self.path_mapping['webui_token'],
        }
        
        # config.yaml 恢复策略：
        # - SKIP_CONFIG_RESTORE=true（默认）：不直接覆盖 config.yaml（由 entrypoint.sh 重新生成），
        #   但恢复到 config.yaml.restored 供 entrypoint.sh 合并用户配置（platforms 等区块）
        # - SKIP_CONFIG_RESTORE=false：直接覆盖 config.yaml
        if not skip_restore:
            restore_mapping['config/config.yaml'] = self.path_mapping['config']
        else:
            logger.info("Skipping config.yaml direct restore (will be regenerated by entrypoint.sh)")
            # 恢复到 .restored 文件，供 entrypoint.sh 合并用户修改的配置区块
            restored_path = self.hermes_home / 'config.yaml.restored'
            src = download_dir / 'config' / 'config.yaml'
            if src.exists():
                shutil.copy2(src, restored_path)
                logger.info("Restored config.yaml to config.yaml.restored for merge")
        
        for src_rel, dst in restore_mapping.items():
            src = download_dir / src_rel
            if src.exists():
                try:
                    if src.is_file():
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src, dst)
                        logger.info(f"Restored: {src_rel}")
                    elif src.is_dir():
                        if dst.exists():
                            shutil.rmtree(dst)
                        shutil.copytree(src, dst)
                        logger.info(f"Restored directory: {src_rel}")
                except Exception as e:
                    logger.error(f"Failed to restore {src_rel}: {e}")
            else:
                logger.warning(f"Not found in backup: {src_rel}")
        
        logger.success("Data restoration completed")


class ConfigFileHandler(FileSystemEventHandler):
    """配置文件变化处理器 - 实时同步到 Dataset 并触发重载"""
    
    # 启动静默期（秒）：在此期间内的文件变更不予备份，避免启动阶段冗余上传
    STARTUP_GRACE_PERIOD = 30
    
    def __init__(self, manager: DatasetManager):
        self.manager = manager
        self.last_backup_time = 0
        self.backup_cooldown = 5  # 5秒内不重复备份
        self.start_time = time.time()  # 记录处理器创建时间
        self._startup_logged = False
        
    def on_modified(self, event):
        """文件被修改时触发"""
        if event.is_directory:
            return
        
        # 启动静默期：跳过启动阶段的配置变更备份
        elapsed = time.time() - self.start_time
        if elapsed < self.STARTUP_GRACE_PERIOD:
            if not self._startup_logged:
                logger.info(f"In startup grace period ({int(self.STARTUP_GRACE_PERIOD - elapsed)}s remaining), skipping backup for: {event.src_path}")
                self._startup_logged = True
            return
            
        # 只关注关键配置文件
        watched_files = ['config.yaml', '.env', 'auth.json']
        if any(event.src_path.endswith(f) for f in watched_files):
            current_time = time.time()
            if current_time - self.last_backup_time > self.backup_cooldown:
                logger.info(f"Config file changed: {event.src_path}")
                logger.info("Triggering immediate backup...")
                try:
                    self.manager.upload_to_dataset()
                    self.last_backup_time = current_time
                    logger.success("Immediate backup completed")
                    
                    # 尝试触发 Hermes 配置重载
                    self._trigger_reload()
                    
                except Exception as e:
                    logger.error(f"Immediate backup failed: {e}")
    
    def _trigger_reload(self):
        """尝试触发 Hermes 配置重载"""
        # 注意：Hermes 目前没有 config reload 命令
        # 配置将在下次 Space 重启时自动生效
        logger.info("Configuration saved. Please restart Space to apply changes immediately.")


def run_daemon():
    """后台守护进程模式 - 定期同步 + 实时文件监听"""
    logger.info("Starting data sync daemon...")
    
    sync_interval = int(os.environ.get('SYNC_INTERVAL', '60'))  # 默认60秒（实时模式）
    manager = DatasetManager()
    
    if not manager.validate():
        logger.error("Configuration invalid, exiting")
        sys.exit(1)
    
    logger.info(f"Sync interval: {sync_interval} seconds")
    
    # 如果 watchdog 可用，启动文件监听
    observer = None
    if WATCHDOG_AVAILABLE:
        try:
            logger.info("Starting file watcher for real-time sync...")
            event_handler = ConfigFileHandler(manager)
            observer = Observer()
            observer.schedule(event_handler, str(manager.hermes_home), recursive=False)
            observer.start()
            logger.success("File watcher started - config changes will trigger immediate backup")
        except Exception as e:
            logger.error(f"Failed to start file watcher: {e}")
            logger.warning("Falling back to scheduled sync only")
            observer = None
    else:
        logger.warning("Watchdog not available, using scheduled sync only")
    
    try:
        while True:
            try:
                time.sleep(sync_interval)
                logger.info("Performing scheduled backup...")
                manager.upload_to_dataset()
            except KeyboardInterrupt:
                logger.info("Daemon stopped")
                break
            except Exception as e:
                logger.error(f"Sync error: {e}")
    finally:
        # 清理文件监听器
        if observer:
            logger.info("Stopping file watcher...")
            observer.stop()
            observer.join()
            logger.info("File watcher stopped")


def main():
    parser = argparse.ArgumentParser(description='Hermes Agent Data Sync')
    parser.add_argument('action', choices=['backup', 'restore', 'daemon'],
                       help='Action to perform')
    parser.add_argument('--force', '-f', action='store_true',
                       help='Force backup even if no changes')
    
    args = parser.parse_args()
    
    manager = DatasetManager()
    
    if not manager.validate():
        logger.error("Configuration invalid")
        sys.exit(1)
    
    if args.action == 'backup':
        success = manager.upload_to_dataset(force=args.force)
        sys.exit(0 if success else 1)
    
    elif args.action == 'restore':
        success = manager.download_from_dataset()
        sys.exit(0 if success else 1)
    
    elif args.action == 'daemon':
        run_daemon()


if __name__ == '__main__':
    main()
