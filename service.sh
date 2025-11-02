#!/system/bin/sh

# === Magisk 服务入口（必须快速退出）===
# 仅负责启动守护进程，绝不阻塞

# 创建日志目录
mkdir -p /data/adb/modules/memory_writeback 2>/dev/null

# 后台启动真正的业务逻辑
nohup /data/adb/modules/memory_writeback/start.sh \
  > /dev/null 2>&1 &

# 立即退出（让 Magisk 继续）
exit 0
