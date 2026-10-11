#!/bin/sh
# A11y KeepAlive 看门狗 (v3.2): 守护进程消失/卡死时自动复活
DIR="${0%/*}"
while true; do
    sleep 30
    [ -f "$DIR/disable" ] && continue
    pid=$(ps -ef 2>/dev/null | grep '[M]onitor_Process.sh' | awk 'NR==1{print $2}')
    if [ -z "$pid" ]; then
        echo "$(date '+%F %T') [wd] 守护进程不在，正在复活" >> /data/adb/a11y_keepalive/a11y_keepalive.log
        cp -f "$DIR/config/Monitor.sh" "$DIR/Monitor_Process.sh" 2>/dev/null
        chmod 0755 "$DIR/Monitor_Process.sh" 2>/dev/null
        ( exec setsid sh "$DIR/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
    else
        # 卡死检测: 用 heartbeat(每轮必touch),不依赖状态文件(内容不变时不会更新)
        stale=$(( $(date +%s) - $(stat -c %Y /data/adb/a11y_keepalive/heartbeat 2>/dev/null || echo 0) ))
        int=$(sed -n 's/^INTERVAL=//p' /data/adb/a11y_keepalive/a11y_keepalive.conf 2>/dev/null | head -1)
        [ -z "$int" ] && int=20
        limit=$((int * 4 + 60))
        if [ "$stale" -gt "$limit" ]; then
            echo "$(date '+%F %T') [wd] 状态文件 ${stale}s 未更新(> ${limit}s)，判定卡死，重启守护" >> /data/adb/a11y_keepalive/a11y_keepalive.log
            kill -9 "$pid" 2>/dev/null
        fi
    fi
done
