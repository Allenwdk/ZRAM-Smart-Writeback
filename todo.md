切换应用后计时30s，如果仍然在当前应用就执行echo all > /sys/block/zram0/idle，再计时15s如果依旧在当前应用再进行回写（done）
