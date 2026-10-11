#!/system/bin/sh
# A11y KeepAlive 动作脚本 (v3.1-hotfix)
# start/stop/status/state/toggle/restart

MODDIR="${0%/*}"
STATE_FILE="/data/media/0/Android/a11y_keepalive.state"
LOG_PATH="/data/media/0/Android/a11y_keepalive.log"

monitor_pid() {
	ps -ef 2>/dev/null | grep '[M]onitor_Process.sh' | awk 'NR==1{print $2}'
}

is_running() {
	[ -f "${MODDIR}/disable" ] && return 1
	[ -n "$(monitor_pid)" ]
}

move_to_system_cgroup() {
	pid="$1"
	[ -z "${pid}" ] && return 1
	# KernelSU WebUI 启动的进程会继承管理器 app cgroup，离开页面后可能被冻结。
	# 移到 system/background；失败不影响后续启动。
	echo "${pid}" > /sys/fs/cgroup/system/uid_0/cgroup.procs 2>/dev/null
	echo "${pid}" > /dev/cpuset/background/tasks 2>/dev/null
	echo "${pid}" > /dev/cpuctl/background/tasks 2>/dev/null
	return 0
}

start_monitor() {
	rm -f "${MODDIR}/disable" 2>/dev/null
	if is_running; then
		move_to_system_cgroup "$(monitor_pid)"
		echo "running"
		return 0
	fi

	# 每次启动使用最新 Monitor.sh，避免旧 Monitor_Process.sh 缓存。
	cp -f "${MODDIR}/config/Monitor.sh" "${MODDIR}/Monitor_Process.sh" 2>/dev/null
	chmod 0755 "${MODDIR}/Monitor_Process.sh" 2>/dev/null
	mkdir -p /data/media/0/Android 2>/dev/null
	echo "A11y KeepAlive：正在启动" > "${STATE_FILE}" 2>/dev/null

	( exec setsid sh "${MODDIR}/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
	sleep 1
	pid="$(monitor_pid)"
	[ -z "${pid}" ] && ( nohup sh "${MODDIR}/Monitor_Process.sh" >/dev/null 2>&1 </dev/null & )
	sleep 1
	pid="$(monitor_pid)"
	if [ -n "${pid}" ]; then
		move_to_system_cgroup "${pid}"
		echo "running"
		return 0
	fi
	echo "A11y KeepAlive：启动失败，请查看运行日志" > "${STATE_FILE}" 2>/dev/null
	mylog "守护进程启动失败" "error" 2>/dev/null
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