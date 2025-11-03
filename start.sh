#!/system/bin/sh

# === 等待系统完全启动 ===
function boot() {
  while [ "$(getprop sys.boot_completed)" != '1' ]; do
    sleep 10
  done
  # 额外等待系统服务稳定
  sleep 30
  log "✅ 系统已就绪 (boot_completed=1)"
}

# === 初始化 ===
LOG_FILE="/data/adb/modules/memory_writeback/memory_writeback.log"
:> $LOG_FILE 2>/dev/null  # 清空旧日志

log() {
  local msg="[$(date +'%T')] $1"
  echo "$msg" >> $LOG_FILE 2>/dev/null
  echo "$msg"
}

# === 新增：CPU 亲和性控制（绑定小核）===
bind_to_little_cores() {
  # 获取小核ID（通常0-3）
  local little_cores=$(lscpu 2>/dev/null | grep 'CPU(s):' | head -2 | tail -1 | awk '{print $2}')
  
  if [ -n "$little_cores" ] && [ "$little_cores" -gt 0 ]; then
    local core_ids=$(seq 0 $((little_cores - 1)) | tr '\n' ',' | sed 's/,$//')
    taskset -p "0x$((2#$core_ids))" $$ >/dev/null 2>&1
    log "🔧 绑定到小核: $core_ids"
  fi
}

# === 新增：动态轮询间隔 ===
get_sleep_time() {
  # 基础间隔（秒）
  local base_interval=5
  
  # 根据系统负载调整
  local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0.5")
  if (( $(echo "$load_avg > 2.0" | bc -l 2>/dev/null || echo "0") )); then
    echo $((base_interval * 2))  # 繁忙时加倍
  elif (( $(echo "$load_avg < 0.5" | bc -l 2>/dev/null || echo "1") )); then
    echo $((base_interval / 2))  # 空闲时减半
  else
    echo $base_interval
  fi
}

# === 防止多实例 ===
if pidof -o %PPID -x "$0" >/dev/null; then
  log "⚠️ 检测到重复实例，退出"
  exit 1
fi

# === 初始化 ===
bind_to_little_cores  # 先绑定再做其他操作
log "✅ 系统初始化完成"

# === 初始化 busybox ===
if [ -f /data/adb/magisk/busybox ]; then
  ln -sf /data/adb/magisk/busybox /system/bin/bc 2>/dev/null
  ln -sf /data/adb/magisk/busybox /system/bin/awk 2>/dev/null
  log "🔧 已初始化 busybox 工具链"
else
  log "⚠️ 注意: Magisk busybox 未找到! 可能影响精度"
fi

# === zram 设备检测（终极兼容版）===
log "🔍 正在检测 zram 设备..."
ZRAM_DEV=""

# 1. 第一重：标准路径搜索（/sys/block）
for dev in /sys/block/zram*; do
  if [ -d "$dev" ] && [ -w "$dev/idle" ] 2>/dev/null; then
    ZRAM_DEV="$dev"
    log "✅ 在 /sys/block 找到 zram: $dev"
    break
  fi
done

# 2. 第二重：备选路径搜索（/sys/devices/virtual/block）
if [ -z "$ZRAM_DEV" ]; then
  for dev in /sys/devices/virtual/block/zram*; do
    if [ -d "$dev" ] && [ -w "$dev/idle" ] 2>/dev/null; then
      ZRAM_DEV="$dev"
      log "✅ 在 /sys/devices/virtual/block 找到 zram: $dev"
      break
    fi
  done
fi

# 3. 第三重：直接验证
if [ -z "$ZRAM_DEV" ]; then
  for i in {0..9}; do
    dev1="/sys/block/zram$i"
    dev2="/sys/devices/virtual/block/zram$i"
    
    if [ -w "$dev1/idle" ] 2>/dev/null; then
      ZRAM_DEV="$dev1"
      log "✅ 通过直接验证找到 zram: $dev1"
      break
    elif [ -w "$dev2/idle" ] 2>/dev/null; then
      ZRAM_DEV="$dev2"
      log "✅ 通过直接验证找到 zram: $dev2"
      break
    fi
  done
fi

# 4. 最终验证
if [ -z "$ZRAM_DEV" ] || [ ! -w "$ZRAM_DEV/idle" ]; then
  log "❌ 错误: 未找到有效的 zram 设备!"
  log "🔍 调试: 检查 /sys/block"
  ls -ld /sys/block/zram* 2>&1 | while read line; do log "   $line"; done
  
  log "🔍 调试: 检查 /sys/devices/virtual/block"
  ls -ld /sys/devices/virtual/block/zram* 2>&1 | while read line; do log "   $line"; done
  
  log "🔍 调试: 检查 /proc/swaps"
  cat /proc/swaps 2>&1 | while read line; do log "   $line"; done
  
  exit 1
fi

log "✅ 最终选定 zram 设备: $ZRAM_DEV"

# === 配置参数 ===
THROTTLE_SEC=300                # 命令节流时间（秒）
MEM_THRESHOLD_85=85            # 内存阈值1
MEM_THRESHOLD_90=90            # 内存阈值2
MEM_LOG_LEVEL=0                # 0=精简日志, 1=详细日志
LOCK_DEBOUNCE_SEC=10           # 锁屏事件去重时间
APP_SWITCH_DEBOUNCE=5          # 应用切换去重时间

# === 核心函数 ===
perform_writeback() {
  local now=$(date +%s)
  if [ -z "$LAST_WRITEBACK" ] || [ $((now - LAST_WRITEBACK)) -ge $THROTTLE_SEC ]; then
    if echo idle > "$ZRAM_DEV/writeback" 2>/dev/null; then
      log "💡 触发 zram 回写操作 (writeback)"
      LAST_WRITEBACK=$now
    else
      log "❌ zram 回写失败! 请检查权限"
    fi
  else
    log "⏳ 操作节流中（等待 $((THROTTLE_SEC - (now - LAST_WRITEBACK))) 秒）"
  fi
}

perform_idle_all_and_writeback() {
  local now=$(date +%s)
  if [ -z "$LAST_WRITEBACK" ] || [ $((now - LAST_WRITEBACK)) -ge $THROTTLE_SEC ]; then
    if echo all > "$ZRAM_DEV/idle" 2>/dev/null; then
      log "💤 标记所有 zram 内存页为 idle"
      perform_writeback
    else
      log "❌ idle all 操作失败"
    fi
  fi
}

# === 全局状态变量 ===
LOCKED="false"          # 锁屏状态
LAST_LOCK_EVENT=0       # 上次锁屏事件时间
LOCK_DELAY_SEC=90       # 锁屏延迟回写时间
LOCK_TIMER_PID=0        # 延迟计时器PID
LOCK_STATE_FILE="/data/adb/modules/memory_writeback/lock_state"
last_mem_percent=0      # 用于内存日志优化

# === 初始化锁屏状态 ===
echo "unlocked" > "$LOCK_STATE_FILE" 2>/dev/null

# === 锁屏状态监控（使用 dumpsys window policy）===
monitor_lock_screen() {
  local last_locked="unknown"
  
  log "🔍 开始锁屏监控 (dumpsys window policy)"
  
  while true; do
    # 动态计算睡眠时间（锁屏检测可以稍慢）
    sleep_time=$(get_sleep_time)
    [ $sleep_time -lt 3 ] && sleep_time=3
    
    # 恢复原始 dumpsys 方法
    is_locked=$(dumpsys window policy 2>/dev/null | grep mIsShowing)
    current_locked="unknown"
    
    if echo "$is_locked" | grep -q 'mIsShowing=true'; then
      current_locked="true"
    elif echo "$is_locked" | grep -q 'mIsShowing=false'; then
      current_locked="false"
    fi
    
    # 状态变化检测
    if [ "$current_locked" != "unknown" ] && [ "$current_locked" != "$last_locked" ]; then
      if [ "$current_locked" = "true" ]; then
        log "🔒 检测到锁屏状态: 设备已锁屏"
        LOCKED="true"
        LAST_LOCK_EVENT=$(date +%s)
        echo "locked" > "$LOCK_STATE_FILE"
        
        # 启动延迟回写计时器
        start_delayed_writeback
        
      else
        log "🔓 检测到解锁状态: 设备已解锁"
        LOCKED="false"
        LAST_LOCK_EVENT=0
        echo "unlocked" > "$LOCK_STATE_FILE"
        
        # 取消任何进行中的延迟回写
        cancel_delayed_writeback
      fi
      last_locked="$current_locked"
    fi
    
    sleep $sleep_time
  done &
}

# === 延迟回写计时器（兼容子 shell）===
start_delayed_writeback() {
  # 1. 清理旧计时器
  cancel_delayed_writeback
  
  # 2. 记录延迟任务
  echo "$(date +%s) $LOCK_DELAY_SEC" > "$LOCK_STATE_FILE.delay"
  
  # 3. 启动监控进程（只启动一个）
  if [ -z "$DELAY_MONITOR_PID" ] || ! kill -0 $DELAY_MONITOR_PID 2>/dev/null; then
    (
      # 关键修复：在子 shell 中定义必要函数
      date_cmd() {
        if command -v date >/dev/null 2>&1; then
          date "$@"
        else
          if [ -f /data/adb/magisk/busybox ]; then
            /data/adb/magisk/busybox date "$@"
          fi
        fi
      }
      
      log_local() {
        local msg="[$(date_cmd +'%T')] $1"
        echo "$msg" >> "$LOG_FILE"
      }
      
      writeback_local() {
        if echo idle > "$ZRAM_DEV/writeback" 2>/dev/null; then
          log_local "💡 触发 zram 回写操作 (writeback)"
        else
          log_local "❌ zram 回写失败! 请检查权限"
        fi
      }
      
      idle_all_local() {
        if echo all > "$ZRAM_DEV/idle" 2>/dev/null; then
          log_local "💤 标记所有 zram 内存页为 idle"
          writeback_local
        else
          log_local "❌ idle all 操作失败"
        fi
      }
      
      # 监控循环
      while true; do
        if [ -f "$LOCK_STATE_FILE.delay" ]; then
          start_time=$(cut -d' ' -f1 "$LOCK_STATE_FILE.delay")
          delay_sec=$(cut -d' ' -f2 "$LOCK_STATE_FILE.delay")
          elapsed=$(( $(date_cmd +%s) - start_time ))
          
          if [ $elapsed -ge $delay_sec ]; then
            # 检查是否仍锁屏
            if [ "$(cat "$LOCK_STATE_FILE" 2>/dev/null)" = "locked" ]; then
              log_local "⏳ 锁屏已持续 $LOCK_DELAY_SEC 秒，执行深度回写"
              idle_all_local
            else
              log_local "⏳ 锁屏延迟取消: 设备已解锁"
            fi
            rm -f "$LOCK_STATE_FILE.delay"
          fi
        fi
        sleep_cmd() {
          if command -v sleep >/dev/null 2>&1; then
            sleep "$@"
          else
            if [ -f /data/adb/magisk/busybox ]; then
              /data/adb/magisk/busybox sleep "$@"
            else
              ping -c "$1" 127.0.0.1 >/dev/null 2>&1
            fi
          fi
        }
        sleep_cmd 5
      done
    ) &
    DELAY_MONITOR_PID=$!
    log "⏳ 启动延迟监控进程 (PID: $DELAY_MONITOR_PID)"
  fi
  
  log "⏳ 已设置锁屏延迟回写 ($LOCK_DELAY_SEC 秒)"
}

# === 取消延迟回写 ===
cancel_delayed_writeback() {
  if [ -f "$LOCK_STATE_FILE.lock" ]; then
    timer_pid=$(cat "$LOCK_STATE_FILE.lock" 2>/dev/null)
    
    if [ -n "$timer_pid" ] && kill -0 $timer_pid 2>/dev/null; then
      kill -9 $timer_pid 2>/dev/null
      log "⏳ 取消延迟回写计时器 (PID: $timer_pid)"
    fi
    
    rm -f "$LOCK_STATE_FILE.lock" 2>/dev/null
  fi
}

# === 应用切换检测（使用 dumpsys window）===
monitor_app_switch() {
  local last_pkg=""
  local app_switch_time=0
  local stage_1_done="false"   # 30秒标记
  local stage_2_done="false"   # 45秒标记
  
  log "🔍 开始应用切换监控 (dumpsys window)"
  
  while true; do
    # 动态计算睡眠时间（应用切换需要稍频繁）
    sleep_time=$(get_sleep_time)
    [ $sleep_time -lt 1 ] && sleep_time=1
    
    # 恢复原始 dumpsys 方法
    current_focus=$(dumpsys window 2>/dev/null | grep mCurrentFocus)
    
    # POSIX 兼容的包名提取
    pkg_name=""
    
    # 模式1: 标准格式 (u0 com.app/.Activity)
    if [ -z "$pkg_name" ]; then
      pkg_name=$(echo "$current_focus" | 
        sed -n 's/.*u0 \([a-z][a-z0-9_]*\.[^ \/]*\).*/\1/p' | 
        head -1)
    fi
    
    # 模式2: MIUI/HarmonyOS 格式 (cmp=com.app/.Activity)
    if [ -z "$pkg_name" ]; then
      pkg_name=$(echo "$current_focus" | 
        sed -n 's/.*cmp=\([a-z][a-z0-9_]*\.[^ ,]*\).*/\1/p' | 
        head -1)
    fi
    
    # 模式3: 通用包名格式
    if [ -z "$pkg_name" ]; then
      pkg_name=$(echo "$current_focus" | 
        sed -n 's/.*\([a-z][a-z0-9_]*\.[a-z0-9_]*\.[a-z0-9_]*\).*/\1/p' | 
        head -1)
    fi
    
    # 验证包名格式
    if [ -n "$pkg_name" ] && echo "$pkg_name" | grep -qE '^[a-z][a-z0-9_]*(\.[a-z0-9_]*)+$'; then
      # === 关键修复：跳过 systemui 但不更新状态 ===
      if [ "$pkg_name" = "com.android.systemui" ]; then
        continue  # 跳过回写，且不更新 last_pkg
      fi
      
      # 排除其他系统应用
      if echo "$pkg_name" | grep -qvE '^(com\.android\.settings|com\.android\.launcher|com\.miui\.keyguard)$'; then
        # 检测到应用切换
        if [ "$pkg_name" != "$last_pkg" ] && [ -n "$last_pkg" ]; then
          log "📱 应用切换: $last_pkg → $pkg_name"
          # 重置延时处理状态和时间
          app_switch_time=$(date +%s)
          stage_1_done="false"
          stage_2_done="false"
        fi
        last_pkg="$pkg_name"  # 仅在有效应用切换时更新
        
        # 如果已经发生应用切换，检查延时处理
        if [ $app_switch_time -gt 0 ]; then
          current_time=$(date +%s)
          elapsed_time=$((current_time - app_switch_time))
          
          # 30秒后执行 idle all
          if [ "$stage_1_done" = "false" ] && [ $elapsed_time -ge 30 ]; then
            if echo all > "$ZRAM_DEV/idle" 2>/dev/null; then
              log "💤 应用停留30秒，标记所有 zram 内存页为 idle"
              stage_1_done="true"
            else
              log "❌ idle all 操作失败"
            fi
          fi
          
          # 45秒后执行回写 (30+15)
          if [ "$stage_1_done" = "true" ] && [ "$stage_2_done" = "false" ] && [ $elapsed_time -ge 45 ]; then
            if echo idle > "$ZRAM_DEV/writeback" 2>/dev/null; then
              log "💡 应用停留45秒，触发 zram 回写操作"
              stage_2_done="true"
            else
              log "❌ zram 回写失败! 请检查权限"
            fi
          fi
        fi
      fi
    fi
    
    sleep $sleep_time
  done &
}

# === 内存监控线程 ===
monitor_memory() {
  while true; do
    # 获取基础内存数据（一次性读取，避免多次调用 awk）
    meminfo=$(cat /proc/meminfo 2>/dev/null || echo "")
    
    total_kb=$(echo "$meminfo" | awk '/^MemTotal/{print $2}')
    available_kb=$(echo "$meminfo" | awk '/^MemAvailable/{print $2}')
    
    # 备用方案
    if [ -z "$available_kb" ] || [ "$available_kb" -le 0 ]; then
      free_kb=$(echo "$meminfo" | awk '/^MemFree/{print $2}')
      buffers_kb=$(echo "$meminfo" | awk '/^Buffers/{print $2}')
      cached_kb=$(echo "$meminfo" | awk '/^Cached[[:space:]]/{print $2}')
      [ -z "$free_kb" ] && free_kb=0
      [ -z "$buffers_kb" ] && buffers_kb=0
      [ -z "$cached_kb" ] && cached_kb=0
      available_kb=$(echo "$free_kb + $buffers_kb + $cached_kb" | bc 2>/dev/null || echo 0)
    fi

    # 物理内存使用率计算
    if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ] && [ -n "$available_kb" ]; then
      used_kb=$((total_kb - available_kb))
      if [ $used_kb -lt 0 ]; then
        log "⚠️ 内存计算异常: used_kb=$used_kb (重置为0)"
        used_kb=0
      fi
      mem_percent=$((used_kb * 100 / total_kb))
    else
      mem_percent=0
      log "⚠️ 内存数据异常! total_kb=$total_kb, available_kb=$available_kb"
    fi

    # zram 数据
    zram_orig_kb=0
    zram_memused_kb=0
    if [ -f "$ZRAM_DEV/mm_stat" ]; then
      orig=$(awk '{print $1}' "$ZRAM_DEV/mm_stat" 2>/dev/null)
      memused=$(awk '{print $3}' "$ZRAM_DEV/mm_stat" 2>/dev/null)
      orig=$(echo "$orig" | tr -cd '0-9' || echo 0)
      memused=$(echo "$memused" | tr -cd '0-9' || echo 0)
      [ -z "$orig" ] && orig=0
      [ -z "$memused" ] && memused=0
      zram_orig_kb=$((orig / 1024))
      zram_memused_kb=$((memused / 1024))
      
      if [ $zram_memused_kb -gt $((total_kb * 2)) ]; then
        log "⚠️ zram 异常: memused=$zram_memused_kb KB (总内存=$total_kb KB). 重置为0"
        zram_memused_kb=0
      fi
    fi

    # 交换空间数据
    swap_total_kb=$(echo "$meminfo" | awk '/^SwapTotal/{print $2}' || echo 0)
    swap_free_kb=$(echo "$meminfo" | awk '/^SwapFree/{print $2}' || echo 0)
    swap_percent=0
    if [ "$swap_total_kb" -gt 0 ]; then
      swap_used=$((swap_total_kb - swap_free_kb))
      swap_percent=$((swap_used * 100 / swap_total_kb))
    fi

    # 智能日志输出（仅在变化时输出详细日志）
    if [ $mem_percent -gt 80 ] || [ $zram_orig_kb -gt 100000 ] || [ $last_mem_percent -ne $mem_percent ]; then
      if [ $MEM_LOG_LEVEL -eq 1 ]; then
        log "📊 内存使用: $used_kb/$total_kb KB ($mem_percent%)"
        log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
        log "🔍 交换空间: 总量=$swap_total_kb KB, 空闲=$swap_free_kb KB (使用率=$swap_percent%)"
      else
        log "📊 内存: $mem_percent% | zram: 原始=$zram_orig_kb KB, 占用=$zram_memused_kb KB"
      fi
    else
      log "📊 内存: $mem_percent%"
    fi
    last_mem_percent=$mem_percent

    # 阈值检查
    if [ $mem_percent -gt $MEM_THRESHOLD_90 ]; then
      log "🔥 严重警告: 物理内存 $mem_percent% > $MEM_THRESHOLD_90%! 执行 idle all + 回写"
      log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
      log "🔍 交换空间: 总量=$swap_total_kb KB, 空闲=$swap_free_kb KB (使用率=$swap_percent%)"
      perform_idle_all_and_writeback
    elif [ $mem_percent -gt $MEM_THRESHOLD_85 ]; then
      log "⚠️ 警告: 物理内存 $mem_percent% > $MEM_THRESHOLD_85%! 触发回写操作"
      log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
      perform_writeback
    fi

    # 动态睡眠时间
    sleep_time=$(get_sleep_time)
    [ $sleep_time -lt 5 ] && sleep_time=5
    sleep $sleep_time
  done
}

# === 主函数 ===
main() {
  # 等待系统启动
  boot
  
  # 启动所有监控器
  monitor_lock_screen
  monitor_app_switch
  monitor_memory
  
  # 保持进程存活
  while true; do
    sleep 300
  done
}

# === 执行主函数 ===
main
