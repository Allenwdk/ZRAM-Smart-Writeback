#!/system/bin/sh

# === 等待系统完全启动 ===
function boot() {
  while [ "$(getprop sys.boot_completed)" != '1' ]; do
    sleep 20
  done
  log "✅ 系统已就绪 (boot_completed=1)"
}

# === 初始化 ===
LOG_FILE="/data/adb/modules/memory_writeback/memory_writeback.log"
mkdir -p /data/adb/modules/memory_writeback 2>/dev/null
:> $LOG_FILE 2>/dev/null

log() {
  local msg="[$(date +'%T')] $1"
  echo "$msg" >> $LOG_FILE 2>/dev/null
  echo "$msg"
}

# === 配置参数 ===
THROTTLE_SEC=60                # 命令节流时间（秒）
MEM_THRESHOLD_85=85            # 内存阈值1
MEM_THRESHOLD_90=90            # 内存阈值2
MEM_LOG_LEVEL=0                # 0=精简日志, 1=详细日志
LOCK_DEBOUNCE_SEC=10           # 锁屏事件去重时间
APP_SWITCH_DEBOUNCE=5          # 应用切换去重时间

# === 等待系统启动 ===
boot

# === 初始化 busybox ===
if [ -f /data/adb/magisk/busybox ]; then
  ln -sf /data/adb/magisk/busybox /system/bin/bc 2>/dev/null
  ln -sf /data/adb/magisk/busybox /system/bin/awk 2>/dev/null
  log "🔧 已初始化 busybox 工具链"
else
  log "⚠️ 注意: Magisk busybox 未找到! 可能影响精度"
fi

# === zram 设备检测 ===
ZRAM_DEV=$(find /sys/block -name 'zram*' -type d -writable -print -quit 2>/dev/null)
if [ -z "$ZRAM_DEV" ]; then
  log "❌ 错误: 未找到可写的 zram 设备!"
  exit 1
fi
log "✅ 检测到 zram 设备: $ZRAM_DEV"

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

# === 事件监控线程（终极精准版）===
LOCK_SCREEN_PATTERNS=(
  "I .*wm_screen_off"                  # AOSP 标准
  "180\)"                              # 事件码（带右括号防误报）
  "Display Power: state=OFF"           # 三星/OneUI
  "Going to sleep due to"              # 小米/华为
  "user_inactive"                      # 华为/HarmonyOS
  "android.policy: Going to sleep"     # 旧版 ROM
  "PowerManagerService: Going to sleep" # 系统服务
)

logcat -b all | while read -r line; do
  # 1. 锁屏事件检测
  if echo "$line" | grep -qE "$(IFS=\|; echo "${LOCK_SCREEN_PATTERNS[*]}")"; then
    # 来源验证（排除误报）
    if echo "$line" | grep -qE "WindowManager|PowerManager|android\.policy"; then
      current_time=$(date +%s)
      if [ -z "$LAST_LOCK_TIME" ] || [ $((current_time - LAST_LOCK_TIME)) -gt $LOCK_DEBOUNCE_SEC ]; then
        log "🔒 检测到锁屏事件 (Verified)"
        perform_idle_all_and_writeback
        LAST_LOCK_TIME=$current_time
      fi
    fi
  fi
  
  # 2. 应用切换检测
  if echo "$line" | grep -q 'Displayed'; then
    # 智能提取包名（支持所有 ROM 格式）
    pkg_name=$(echo "$line" | grep -oP '(?<=Displayed )[^: ]+(?=/)' | head -1)
    if [ -z "$pkg_name" ]; then
      pkg_name=$(echo "$line" | grep -oP '(?<=Displayed: )[^/]+(?=/)' | head -1)
    fi
    
    # 严格验证包名格式
    if [[ "$pkg_name" =~ \. ]] && [ -n "$pkg_name" ]; then
      # 排除系统 UI 和锁屏应用
      if [[ ! "$pkg_name" =~ ^(com\.android\.systemui|com\.android\.keyguard|com\.miui\.keyguard)$ ]]; then
        current_time=$(date +%s)
        # 应用切换去重
        if [ -z "$LAST_APP_SWITCH" ] || [ $((current_time - LAST_APP_SWITCH)) -gt $APP_SWITCH_DEBOUNCE ]; then
          log "📱 应用切换: $pkg_name"
          perform_writeback
          LAST_APP_SWITCH=$current_time
        fi
      fi
    fi
  fi
done &

# === 内存监控线程（智能日志）===
while true; do
  # 1. 获取基础内存数据
  total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
  available_kb=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
  
  # 备用方案：旧内核无 MemAvailable
  if [ -z "$available_kb" ] || [ "$available_kb" -le 0 ]; then
    free_kb=$(awk '/^MemFree/{print $2}' /proc/meminfo 2>/dev/null)
    buffers_kb=$(awk '/^Buffers/{print $2}' /proc/meminfo 2>/dev/null)
    cached_kb=$(awk '/^Cached[[:space:]]/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$free_kb" ] && free_kb=0
    [ -z "$buffers_kb" ] && buffers_kb=0
    [ -z "$cached_kb" ] && cached_kb=0
    available_kb=$(echo "$free_kb + $buffers_kb + $cached_kb" | bc 2>/dev/null || echo 0)
  fi

  # 2. 关键修复：物理内存使用率计算
  if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ] && [ -n "$available_kb" ]; then
    used_kb=$((total_kb - available_kb))
    # 防负数保护
    if [ $used_kb -lt 0 ]; then
      log "⚠️ 内存计算异常: used_kb=$used_kb (重置为0)"
      used_kb=0
    fi
    mem_percent=$((used_kb * 100 / total_kb))
  else
    mem_percent=0
    log "⚠️ 内存数据异常! total_kb=$total_kb, available_kb=$available_kb"
  fi

  # 3. zram 特殊数据（仅用于日志）
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
    
    # 防御性检查
    if [ $zram_memused_kb -gt $((total_kb * 2)) ]; then
      log "⚠️ zram 异常: memused=$zram_memused_kb KB (总内存=$total_kb KB). 重置为0"
      zram_memused_kb=0
    fi
  fi

  # 4. 交换空间数据
  swap_total_kb=$(awk '/^SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_free_kb=$(awk '/^SwapFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_percent=0
  if [ "$swap_total_kb" -gt 0 ]; then
    swap_used=$((swap_total_kb - swap_free_kb))
    swap_percent=$((swap_used * 100 / swap_total_kb))
  fi

  # 5. 智能日志输出
  if [ $MEM_LOG_LEVEL -eq 1 ]; then
    log "📊 内存使用: $used_kb/$total_kb KB ($mem_percent%)"
    log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
    log "🔍 交换空间: 总量=$swap_total_kb KB, 空闲=$swap_free_kb KB (使用率=$swap_percent%)"
  else
    if [ $mem_percent -gt 80 ] || [ $zram_orig_kb -gt 100000 ]; then
      log "📊 内存: $mem_percent% | zram: 原始=$zram_orig_kb KB, 占用=$zram_memused_kb KB"
    else
      log "📊 内存: $mem_percent%"
    fi
  fi

  # 6. 阈值检查
  if [ $mem_percent -gt $MEM_THRESHOLD_90 ]; then
    log "🔥 严重警告: 物理内存 $mem_percent% > $MEM_THRESHOLD_90%! 执行 idle all + 回写"
    # 高负载时自动记录详细状态
    log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
    log "🔍 交换空间: 总量=$swap_total_kb KB, 空闲=$swap_free_kb KB (使用率=$swap_percent%)"
    perform_idle_all_and_writeback
  elif [ $mem_percent -gt $MEM_THRESHOLD_85 ]; then
    log "⚠️ 警告: 物理内存 $mem_percent% > $MEM_THRESHOLD_85%! 触发回写操作"
    log "🔍 详情: 可用=$available_kb KB | zram(原始=$zram_orig_kb KB, 物理占用=$zram_memused_kb KB)"
    perform_writeback
  fi

  sleep 5
done
