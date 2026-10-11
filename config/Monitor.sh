#!/bin/sh
# A11y KeepAlive 守护进程 (v3.2-fix)
# 修复点:
#  ①工作目录改 /data/adb/a11y_keepalive —— 旧版写 /data/media(经FUSE)在守护进程上下文
#    下静默失败,导致状态/日志永远不更新("看起来失效");现在写原始f2fs,任何上下文可写。
#  ②dumpsys/package 解析全部包 timeout(10s) —— binder 卡死不再拖死整轮循环。
#  ③服务清单缓存: getService 只在必要时重算,循环变轻,间隔可缩短到15s,恢复更快。
#  ④每轮给被保活 app 的进程压 oom_score_adj(-800) —— app 被 LMK 杀掉是无障碍
#    "失效"的第一大根因,保开关同时保进程。
#  ⑤状态文件每轮必写(内容变化才更新 mtime),管理器显示真实状态。

# 【v3.2 核心修复】无条件加载 Function.sh：
# v3.1 的致命bug——只在 DIR 为空时才 source，从 service.sh 拉起时 DIR 已导出
# → 跳过加载，而 shell 函数不能跨进程继承 → 守护进程里 write_EAST/mylog/load_config
# 全是"未定义命令"，错误被 >/dev/null 吞掉 → 每轮循环实际什么都没修，
# "看起来在跑"其实从不干活。这正是"失效/被系统卡掉后不恢复"的根因。
[ -n "${DIR:-}" ] || {
    DIR="${0%/*}"
    case "${DIR}" in */config) DIR="${DIR%/*}" ;; esac
    export DIR
}
: "${CONFIG:=/data/adb/a11y_keepalive/a11y_keepalive.conf}"
: "${LOG_PATH:=/data/adb/a11y_keepalive/a11y_keepalive.log}"
: "${STATE_FILE:=/data/adb/a11y_keepalive/a11y_keepalive.state}"
: "${PROP:=${DIR}/module.prop}"
export CONFIG LOG_PATH STATE_FILE PROP
. "${DIR}/config/Function.sh" || exit 1
load_config

WORK=/data/adb/a11y_keepalive
SVC_CACHE="$WORK/svc_cache"
mkdir -p "$WORK" 2>/dev/null

mylog "守护进程启动 v3.2, PID: $$" "daemon"
last_conf="$(stat -c '%Y:%s' "${CONFIG}" 2>/dev/null)"
last_state=""

set_state() {
    local txt="A11y KeepAlive：$1"
    [ -n "${2:-}" ] && txt="$txt($2)"
    if [ "$txt" != "$last_state" ]; then
        printf '%s\n' "$txt" > "$STATE_FILE" 2>/dev/null && last_state="$txt"
    fi
}

# 超时保护的 dumpsys package 解析
resolve_svc() {
    timeout 10 dumpsys package "$1" 2>/dev/null \
        | grep -iE 'ACCESSIBILITY_SERVICE|android\.accessibilityservice\.AccessibilityService' \
        | sed 's/ /\n/g' | grep -F "$1/" | sed '/^$/d' | sort -u
}

# 给目标 app 进程压 oom_score_adj(防被杀)
protect_app() {
    local p
    for p in $(pgrep -f "$1" 2>/dev/null | head -5); do
        [ "$p" = "$$" ] && continue
        cur=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
        [ -n "$cur" ] && [ "$cur" -gt -800 ] 2>/dev/null && echo -800 > "/proc/$p/oom_score_adj" 2>/dev/null
    done
}

set_state "正在启动" "读取应用列表"

cycle=0
while true; do
    if [ -f "${DIR}/disable" ]; then
        set_state "已暂停" "点击启动保活即可恢复"
        sleep 3; continue
    fi

    # 配置热加载
    new_conf="$(stat -c '%Y:%s' "${CONFIG}" 2>/dev/null)"
    if [ "${new_conf}" != "${last_conf}" ]; then
        load_config
        last_conf="${new_conf}"
        : > "$SVC_CACHE" 2>/dev/null
        mylog "配置已热加载" "config"
    fi

    cycle=$((cycle + 1))
    need_fix=""
    invalid=""
    found_services=""
    have_service=0

    # 服务清单: 缓存命中则不跑 dumpsys;每5轮强制刷新一次
    if [ ! -s "$SVC_CACHE" ] || [ $((cycle % 5)) -eq 0 ]; then
        : > "$SVC_CACHE"
        for pkg in ${APPS} ${PACKAGES}; do
            svc="$(resolve_svc "${pkg}")"
            if [ -z "$svc" ]; then
                invalid="${invalid} ${pkg}"
            else
                have_service=1
                printf '%s\n' "$svc" >> "$SVC_CACHE"
            fi
        done
        [ -n "$invalid" ] && mylog "以下应用未声明无障碍服务:${invalid}" "warn"
    else
        have_service=1
    fi

    if [ -s "$SVC_CACHE" ]; then
        found_services="$(tr '\n' ' ' < "$SVC_CACHE" | sed 's/ $//')"
        have_service=1
    fi

    if [ "$have_service" = "1" ]; then
        write_EAST "${found_services}"
        for pkg in ${APPS} ${PACKAGES}; do
            [ "${WHITELIST:-1}" = "1" ] && add_whitelist "${pkg}"
            protect_app "${pkg}"
        done
    fi

    # 逐 user 修复
    for u in ${USERS:-0}; do
        # 必须用 read_EAST_USER(按换行拆分)；直接 settings get 返回冒号串,
        # 会让 grep -qx 永远匹配不到 → 每轮都误判"缺失"反复写库(v3.2初版引入,已修)
        cur_EAST="$(read_EAST_USER "${u}")"
        master="$(timeout 5 settings get secure --user "${u}" accessibility_enabled 2>/dev/null)"
        if [ "${master}" != "1" ]; then
            timeout 5 settings put secure --user "${u}" accessibility_enabled 1 >/dev/null 2>&1
            mylog "user ${u}: 无障碍总开关被关闭，已恢复" "fix"
        fi
        for s in ${found_services}; do
            if ! echo "${cur_EAST}" | grep -qx "${s}"; then
                need_fix="${need_fix} ${s}"
            fi
        done
    done

    if [ -n "${need_fix}" ]; then
        need_fix="$(echo "${need_fix}" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
        write_EAST "${need_fix}"
        fix_count="$(echo "${need_fix}" | wc -w)"
        mylog "已恢复 ${fix_count} 个无障碍开关: ${need_fix}" "fix"
        set_state "运行中" "刚恢复 ${fix_count} 个开关"
        [ "${INTERVAL:-15}" -gt 5 ] 2>/dev/null && sleep 1
    elif [ "${have_service}" = "1" ]; then
        tcount="$(wc -w < "$SVC_CACHE" 2>/dev/null || echo 0)"
        set_state "运行中" "保护 ${tcount} 个无障碍服务"
    else
        set_state "等待应用" "请在 WebUI 的保活应用中保存至少一个包名"
    fi

    touch "$WORK/heartbeat" 2>/dev/null
    sleep "${INTERVAL:-15}"
done
