#!/bin/sh
# A11y KeepAlive 看门狗 (v3.2): 守护进程消失/卡死时自动复活
DIR="${0%/*}"
while true; do
    sleep 30
    [ -f "$DIR/disable" ] && continue
    # 锚定匹配: 只认真正的守护进程(cmdline 恰为 "sh <路径>/Monitor_Process.sh")。
    # 旧版 ps|grep 会命中任何命令行含该文件名的进程(包括检查者自己)——
    # 既漏复活, 又可能把无辜进程当守护杀掉。
    pid=$(pgrep -f "^sh ${DIR}/Monitor_Process[.]sh$" 2>/dev/null | head -1)
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
            echo "$(date '+%F %T') [wd] 心跳 ${stale}s 未更新(> ${limit}s)，判定卡死，重启守护" >> /data/adb/a11y_keepalive/a11y_keepalive.log
            # 杀全部匹配项: 守护进程 + 其挂起的命令替换子shell(只杀一个会漏)
            for p in $(pgrep -f "^sh ${DIR}/Monitor_Process[.]sh$" 2>/dev/null); do
                kill -9 "$p" 2>/dev/null
            done
        fi
    fi
done
