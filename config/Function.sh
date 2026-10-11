#!/system/bin/sh
# ============================================================
# A11y KeepAlive 函数库 (v3.0)
# 目标: 让指定应用的无障碍服务开关一直保持开启
# 针对: 澎湃OS 3.x (MIUI/HyperOS) 无障碍强杀场景
#
# 关键点(与旧版最大的区别):
#  1. 使用系统原生 settings 命令读写 enabled_accessibility_services，
#     不再自己拼字符串(旧版的 bug 源头)。
#  2. 同时保证 accessibility_enabled = 1 (无障碍总开关)。
#  3. 同时写两个 user (0 和 999)，覆盖"手机分身/隐私空间"，
#     两个 user 的无障碍开关互不相同，漏掉一个就会出现
#     "明明开启了却又不生效" 的玄学现象。
# ============================================================

# ---------- 探测设备上真实存在的 user 列表 ----------
# 返回形如 "0 999" 的 user id 列表。
# user 999 = MIUI/HyperOS 的"手机分身/隐私空间", 澎湃OS 上无障碍开关
# 在 user 0 与 999 是分开存的, 必须都写才能保证在所有空间都生效。
detect_users() {
	local ids
	ids="$(ls /data/system/users/ 2>/dev/null | grep -E '^[0-9]+\.xml$' | sed 's/\.xml$//')"
	if [ -z "${ids}" ]; then
		# 退路: 用 pm list users 解析
		ids="$(pm list users 2>/dev/null | grep -oE 'UserInfo\{[0-9]+' | grep -oE '[0-9]+')"
	fi
	# 始终包含 0
	case "${ids}" in
		*0*) ;;
		*) ids="0 ${ids}" ;;
	esac
	USERS="$(echo ${ids} | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' ')"
	USERS="${USERS% }"
	[ -z "${USERS}" ] && USERS="0"
	export USERS
}

# ---------- 配置文件模板 ----------
releaseConfig() {
	cat <<EOF > "${CONFIG}"
# ============================================================
# A11y KeepAlive 配置文件
# 修改本文件后无需重启，服务会在一个周期内自动生效
# ============================================================

# 【必填】需要保活无障碍开关的 APP 包名
# 一行一个，写在下面 APPS 的两个引号之间！
# 示例:
# APPS="
# com.example.app1
# com.example.app2
# "
APPS="
${APPS:-}
"

# 附加包名(旧版兼容项，功能同 APPS)
PACKAGES="
${PACKAGES:-}
"

# 检查周期(秒)。越小恢复越快，越耗电。
# 推荐 15~60。低于 5 会被强制修正为 5。
INTERVAL=${INTERVAL:-20}

# 日志开关 (1=开启 0=关闭)
LOG_ENABLED=${LOG_ENABLED:-1}

# 是否把保活 APP 加入电池优化白名单 (1=是 0=否)
WHITELIST=${WHITELIST:-1}

# 开机时是否先清空所有无障碍开关再重新开启(1=是 0=否)
# 0 更安全，不会影响 APPS 之外的应用
CLEAN_ON_BOOT=${CLEAN_ON_BOOT:-0}

EOF
}

# ---------- 加载配置 ----------
load_config() {
	[ -f "${CONFIG}" ] && . "${CONFIG}"

	# 先探测 user(0 + 隐私空间), 供 read/write_EAST 使用
	detect_users

	APPS=$(echo "${APPS:-}" | sed 's/#.*$//' | sed '/^$/d' | sort | uniq)
	PACKAGES=$(echo "${PACKAGES:-}" | sed 's/#.*$//' | sed '/^$/d' | sort | uniq)

	INTERVAL=$(echo "${INTERVAL:-20}" | tr -cd '0-9')
	[ -z "${INTERVAL}" ] && INTERVAL=20
	[ "${INTERVAL}" -lt 5 ] 2>/dev/null && INTERVAL=5

	LOG_ENABLED=$(echo "${LOG_ENABLED:-1}" | tr -cd '0-1')
	[ -z "${LOG_ENABLED}" ] && LOG_ENABLED=1
	[ "${LOG_ENABLED}" != "0" ] && LOG_ENABLED=1

	WHITELIST=$(echo "${WHITELIST:-1}" | tr -cd '0-1')
	[ -z "${WHITELIST}" ] && WHITELIST=1

	CLEAN_ON_BOOT=$(echo "${CLEAN_ON_BOOT:-0}" | tr -cd '0-1')
	[ -z "${CLEAN_ON_BOOT}" ] && CLEAN_ON_BOOT=0

	# 供子脚本使用的运行周期(ST=检查最短间隔)
	ST="${INTERVAL}"
	CTime="${INTERVAL}"

	# 持久化规范化后的配置
	releaseConfig
}

# ---------- 日志(写到 /dev/null 或文件，几乎零开销) ----------
mylog() {
	[ "${LOG_ENABLED:-1}" = "0" ] && return 0
	local msg="${1:-}"
	[ -z "${msg}" ] && return 0
	echo "[$(date '+%m-%d %H:%M:%S')]${2:+ [$2]}: ${msg}" >> "${LOG_PATH}"
	if [ -f "${LOG_PATH}" ]; then
		local n
		n=$(wc -l < "${LOG_PATH}" 2>/dev/null)
		[ -n "${n}" ] && [ "${n}" -gt 200 ] && sed -i '1d' "${LOG_PATH}"
	fi
	return 0
}

# ---------- 更新模块描述(KernelSU 管理器里可见的运行状态) ----------
change_prop() {
	local status="${1:-运行中}"
	local extra="${2:-}"
	if [ -n "${extra}" ]; then
		echo "A11y KeepAlive：${status}(${extra})"
	else
		echo "A11y KeepAlive：${status}"
	fi > "${STATE_FILE}" 2>/dev/null
}

# ---------- 读取指定 user 当前已启用的无障碍服务(换行分隔) ----------
read_EAST_USER() {
	local u="${1:-0}"
	settings get secure --user "${u}" enabled_accessibility_services 2>/dev/null \
		| tr ':' '\n' \
		| sed 's/^ *//;s/ *$//;s/^null$//;/^$/d' \
		| sort -u
}

# ---------- 读取所有 user 的服务(仅供兼容旧调用/显示) ----------
read_EAST() {
	local u
	for u in ${USERS:-0}; do
		read_EAST_USER "${u}"
	done | sort -u
}

# ---------- 查询包名对应的无障碍服务组件(换行分隔) ----------
# 输出形如: com.pkg/com.pkg.MyAccessibilityService
# 用 dumpsys package 解析清单里的 ACCESSIBILITY_SERVICE 声明。
# 兼容旧版 busybox/bin/getService 的行为, 但改为内联纯 shell, 不依赖外部脚本。
getService() {
	[ -z "${1:-}" ] && return 0

	local tmp="" var result
	for var in ${1}; do
		# Android 各版本 dumpsys 的权限名可能为 ACCESSIBILITY_SERVICE，
		# 也可能输出 android.accessibilityservice.AccessibilityService。
		# 先定位无障碍服务声明，再提取以包名开头的组件 token。
		result="$(dumpsys package "${var}" 2>/dev/null \
			| grep -iE 'ACCESSIBILITY_SERVICE|android\.accessibilityservice\.AccessibilityService' \
			| sed 's/ /\n/g' \
			| grep -F "${var}/" \
			| sed "s#^${var}/\.#${var}/.#" \
			| sed '/^$/d' \
			| sort -u)"
		if [ -n "${result}" ]; then
			tmp="${tmp}${result}\n"
		fi
	done

	# 过滤掉系统设置自身的无障碍(避免误保活)
	printf '%s' "$(printf '%b' "${tmp}" | grep -v "com.android.settings" | sed '/^$/d' | sort -u)"
}

# ---------- 关闭所有无障碍服务(慎用) ----------
clear_EAST() {
	local u
	for u in ${USERS:-0}; do
		settings put secure --user "${u}" enabled_accessibility_services "" >/dev/null 2>&1
	done
	return 0
}

# ---------- 开启指定无障碍服务(不会关闭别的) ----------
# 注意: Android 的 settings 命令【没有】--append 参数,
# 必须自己读出来 -> 拼接 -> 整体写回, 冒号分隔。
# 对 USERS 中每个 user 都执行同样操作。
write_EAST() {
	local svc="${1:-}"
	[ -z "${svc}" ] && return 0

	local u original current existing v new_compact old_compact original_count unique_count
	for u in ${USERS:-0}; do
		original="$(settings get secure --user "${u}" enabled_accessibility_services 2>/dev/null)"
		case "${original}" in
			""|"null") original="" ;;
		esac

		# 完整列表先去重。旧版或多次恢复可能已留下重复组件。
		current="$(printf '%s' "${original}" | tr ':' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
		current="${current% }"
		existing="${current}"
		for v in ${svc}; do
			echo "${existing}" | tr ' ' '\n' | grep -qx "${v}" && continue
			[ -n "${existing}" ] && existing="${existing}:${v}" || existing="${v}"
		done

		# 用去重后的冒号列表比较，避免服务已经存在时反复写入。
		new_compact="$(printf '%s' "${existing}" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ':' | sed 's/:$//')"
		old_compact="$(printf '%s' "${original}" | tr ':' '\n' | sed '/^$/d' | sort -u | tr '\n' ':' | sed 's/:$//')"
		original_count="$(printf '%s' "${original}" | tr ':' '\n' | sed '/^$/d' | wc -l)"
		unique_count="$(printf '%s' "${old_compact}" | tr ':' '\n' | sed '/^$/d' | wc -l)"
		if [ "${new_compact}" != "${old_compact}" ] || [ "${original_count}" -ne "${unique_count}" ]; then
			settings put secure --user "${u}" enabled_accessibility_services "${new_compact}" >/dev/null 2>&1
		fi
	done
	return 0
}

# ---------- 确保无障碍总开关打开 ----------
ensure_master() {
	local u
	for u in ${USERS:-0}; do
		settings put secure --user "${u}" accessibility_enabled 1 >/dev/null 2>&1
		settings put secure --user "${u}" touch_exploration_enabled 1 >/dev/null 2>&1
	done
	return 0
}

# ---------- 取两个集合的交集(遗留函数) ----------
take_same() {
	echo "$1" | sort -u > /tmp/_kA.$$
	echo "$2" | sort -u > /tmp/_kB.$$
	comm -12 /tmp/_kA.$$ /tmp/_kB.$$
	rm -f /tmp/_kA.$$ /tmp/_kB.$$
}

# ---------- 取两个集合的差集(遗留函数) ----------
get_difference() {
	echo "$1" | sort -u > /tmp/_kA.$$
	echo "$2" | sort -u > /tmp/_kB.$$
	comm -23 /tmp/_kA.$$ /tmp/_kB.$$
	rm -f /tmp/_kA.$$ /tmp/_kB.$$
}

# ---------- 时间 ----------
get_time() {
	date '+%H:%M:%S'
}

# ---------- 判断应用是否在列表里 ----------
is_in_list() {
	[ -z "${1:-}" ] || [ -z "${2:-}" ] && return 1
	echo "${2}" | grep -qx "${1}"
}

# ---------- 电池优化白名单 ----------
add_whitelist() {
	local pkg
	for pkg in ${1:-}; do
		dumpsys deviceidle whitelist +"${pkg}" >/dev/null 2>&1
	done
	return 0
}

# ---------- 只保留一个开关(用于把某个 app 的开关设为唯一开启项) ----------
set_only_EAST() {
	[ -z "${1:-}" ] && return 0
	settings put secure enabled_accessibility_services "$1" >/dev/null 2>&1
	return 0
}

# ---------- WebUI 与 action.sh 共用的状态文件 ----------
write_state() {
	echo "$1" > "${STATE_FILE}" 2>/dev/null
}
