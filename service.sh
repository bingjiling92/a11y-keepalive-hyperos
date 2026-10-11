#!/system/bin/sh
# A11y KeepAlive 启动器 (v3.2-fix)
# v3.2: ①工作目录迁到 /data/adb/a11y_keepalive(原始f2fs,任何上下文可写;旧 /data/media 配置自动迁移)
#       ②新增看门狗: 守护进程被杀/卡死后30秒内自动复活(修复"被系统卡掉后永久失效")
#       ③dumpsys 全部加超时保护,不再因binder卡死整轮循环
#       ④删除旧版无效的cgroup防冻结写入(本ROM无uid_0路径,写入全部静默失败)
#       ⑤为被保活app压低oom_score_adj,防LMK杀掉app导致无障碍服务变死(修复"失效")

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
while [ -n "$(dumpsys window policy 2>/dev/null | grep mInputRestricted | grep true)" ]; do sleep 2; done

export DIR="${0%/*}"
export MODDIR="${DIR}"
export VERSION_CACHE="${DIR}/module.prop"
version="$(grep '^version=' "${DIR}/module.prop" | cut -d= -f2)"
versionCode="$(grep '^versionCode=' "${DIR}/module.prop" | cut -d= -f2)"
export version versionCode
export CONFIG="/data/adb/a11y_keepalive/a11y_keepalive.conf"
export LOG_PATH="/data/adb/a11y_keepalive/a11y_keepalive.log"
export STATE_FILE="/data/adb/a11y_keepalive/a11y_keepalive.state"
export PROP="${DIR}/module.prop"
export AS exAS EAS EAST APPS PACKAGES INTERVAL LOG_ENABLED WHITELIST CLEAN_ON_BOOT
export USERS ST CTime LastConf DIR CONFIG LOG_PATH PROP STATE_FILE

# ---- 旧版 FUSE(/data/media) 配置迁移(只迁移一次) ----
OLD_DIR=/data/media/0/Android
mkdir -p /data/adb/a11y_keepalive 2>/dev/null
chmod 0755 /data/adb/a11y_keepalive 2>/dev/null
# ①先迁移旧配置(必须在 symlink 化之前执行——否则旧的实体配置文件会被下面的
#   rm -f 删掉而迁移还没发生，用户的保活应用列表就丢了)
if [ ! -f "$CONFIG" ] && [ -f "$OLD_DIR/a11y_keepalive.conf" ] && [ ! -L "$OLD_DIR/a11y_keepalive.conf" ]; then
    cp "$OLD_DIR/a11y_keepalive.conf" "$CONFIG" 2>/dev/null && echo "$(date '+%F %T') [boot] 已迁移旧配置" >> "$LOG_PATH"
fi
# ②旧路径 symlink 兜底: WebUI(main.js) 仍读写 /data/media/0/Android 旧路径,透明指向新位置
for f in a11y_keepalive.conf a11y_keepalive.log a11y_keepalive.state; do
    if [ ! -L "$OLD_DIR/$f" ]; then
        rm -f "$OLD_DIR/$f" 2>/dev/null
        ln -s "/data/adb/a11y_keepalive/$f" "$OLD_DIR/$f" 2>/dev/null
    fi
done

. "${DIR}/config/Function.sh" || { echo "Function.sh 加载失败" > "$LOG_PATH"; exit 1; }
load_config
LastConf="$(ls -l "${CONFIG%/*}/" 2>/dev/null | grep "${CONFIG##*/}")"

if [ "${LOG_ENABLED:-1}" != "0" ]; then
    { echo "A11y KeepAlive ${version}"; echo "启动时间: $(date '+%Y.%m.%d %X')"; echo "保活应用: ${APPS:-<未配置>}"; } > "${LOG_PATH}"
else
    [ -f "${LOG_PATH}" ] && rm -f "${LOG_PATH}" 2>/dev/null
fi

ensure_master

if [ "${CLEAN_ON_BOOT:-0}" = "1" ]; then
    clear_EAST
    echo "$(date '+%F %T') [boot] 已清空所有无障碍开关" >> "$LOG_PATH"
fi

ALL="${APPS} ${PACKAGES}"
for pkg in ${ALL}; do
    svc="$(timeout 10 dumpsys package "${pkg}" 2>/dev/null | grep -iE 'ACCESSIBILITY_SERVICE' | sed 's/ /\n/g' | grep -F "${pkg}/" | sort -u | head -1)"
    [ -z "$svc" ] && svc="$(getService "${pkg}")"
    [ -z "$svc" ] && continue
    write_EAST "$svc"
    echo "$(date '+%F %T') [init] 已开启: $svc" >> "$LOG_PATH"
    [ "${WHITELIST:-1}" = "1" ] && add_whitelist "${pkg}"
done

# ---- 启动守护进程 ----
cp -f "${DIR}/config/Monitor.sh" "${DIR}/Monitor_Process.sh" 2>/dev/null
chmod 0755 "${DIR}/Monitor_Process.sh" 2>/dev/null

MON_PID=$(pgrep -f "^sh ${DIR}/Monitor_Process[.]sh$" 2>/dev/null | head -1)
if [ -z "${MON_PID}" ]; then
    ( exec setsid sh "${DIR}/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
    sleep 1
fi
pid="${MON_PID:-$(pgrep -f "^sh ${DIR}/Monitor_Process[.]sh$" 2>/dev/null | head -1)}"
if [ -n "${pid}" ]; then
    # 防杀: 守护进程本身 -1000(永不被LMK回收);旧版的cgroup路径在本ROM不存在,已移除
    echo "-1000" > /proc/${pid}/oom_score_adj 2>/dev/null
fi

# ---- 启动看门狗(v3.2): 独立进程,守护消失30s内复活、卡死自动重启 ----
if ! pgrep -f "^sh ${DIR}/watchdog[.]sh$" >/dev/null 2>&1; then
    ( exec setsid sh "${DIR}/watchdog.sh" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
fi
sync
exit 0
