#!/system/bin/sh
# A11y KeepAlive 动作脚本 (v3.1-hotfix)
# start/stop/status/state/toggle/restart

MODDIR="${0%/*}"
STATE_FILE="/data/adb/a11y_keepalive/a11y_keepalive.state"
LOG_PATH="/data/adb/a11y_keepalive/a11y_keepalive.log"

monitor_pid() {
	# 锚定匹配(与 watchdog 一致), 防止误杀命令行含此文件名的其他进程
	pgrep -f "^sh ${MODDIR}/Monitor_Process[.]sh$" 2>/dev/null | head -1
}

is_running() {
	[ -f "${MODDIR}/disable" ] && return 1
	[ -n "$(monitor_pid)" ]
}

protect_pid() {
	# v3.2: 旧版 move_to_system_cgroup 写的 uid_0 路径在本ROM不存在(全部静默失败)，
	# 且 /dev/cpuset/background 会把进程限到小核——反效果。改为直接压 oom_score_adj。
	pid="$1"
	[ -z "${pid}" ] && return 1
	echo "-1000" > "/proc/${pid}/oom_score_adj" 2>/dev/null
	return 0
}

start_monitor() {
	rm -f "${MODDIR}/disable" 2>/dev/null
	if is_running; then
		protect_pid "$(monitor_pid)"
		echo "running"
		return 0
	fi

	# 每次启动使用最新 Monitor.sh，避免旧 Monitor_Process.sh 缓存。
	cp -f "${MODDIR}/config/Monitor.sh" "${MODDIR}/Monitor_Process.sh" 2>/dev/null
	chmod 0755 "${MODDIR}/Monitor_Process.sh" 2>/dev/null
	mkdir -p /data/adb/a11y_keepalive 2>/dev/null
	echo "A11y KeepAlive：正在启动" > "${STATE_FILE}" 2>/dev/null

	( exec setsid sh "${MODDIR}/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
	sleep 1
	pid="$(monitor_pid)"
	[ -z "${pid}" ] && ( nohup sh "${MODDIR}/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & )
	sleep 1
	pid="$(monitor_pid)"
	if [ -n "${pid}" ]; then
		protect_pid "${pid}"
		echo "running"
		return 0
	fi
	echo "A11y KeepAlive：启动失败，请查看运行日志" > "${STATE_FILE}" 2>/dev/null
	echo "[$(date '+%m-%d %H:%M:%S')] [error]: 守护进程启动失败" >> "${LOG_PATH}" 2>/dev/null
	echo "failed"
	return 1
}

stop_service() {
	touch "${MODDIR}/disable" 2>/dev/null
	pid="$(monitor_pid)"
	[ -n "${pid}" ] && kill -TERM "${pid}" 2>/dev/null
	sleep 1
	# 冻结态进程可能暂时不处理 TERM，必须 KILL 并确认 PID 消失。
	pid="$(monitor_pid)"
	if [ -n "${pid}" ]; then
		kill -KILL "${pid}" 2>/dev/null
		i=0
		while [ -d "/proc/${pid}" ] && [ "${i}" -lt 20 ]; do
			sleep 0.1
			i=$((i + 1))
		done
	fi
	echo "A11y KeepAlive：已停止" > "${STATE_FILE}" 2>/dev/null
	echo stopped
}

case "${1:-toggle}" in
	status)
		if is_running; then echo running; else echo stopped; fi
		;;
	state)
		[ -f "${STATE_FILE}" ] && cat "${STATE_FILE}" || echo "无状态记录"
		;;
	start)
		start_monitor
		;;
	stop)
		stop_service
		;;
	restart)
		stop_service >/dev/null
		rm -f "${MODDIR}/disable" 2>/dev/null
		start_monitor
		;;
	toggle)
		if is_running; then stop_service; else start_monitor; fi
		;;
	*)
		echo "Usage: action.sh [start|stop|restart|status|state|toggle]"
		exit 1
		;;
esac