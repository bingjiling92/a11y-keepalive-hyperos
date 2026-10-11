#!/system/bin/sh
# ============================================================
# A11y KeepAlive 安装脚本 (v3.0)
# MODPATH 由 Magisk / KernelSU 安装器提供
#
# 新版与旧版安装脚本的区别:
#  - 配置文件格式与新 Function.sh 的 releaseConfig 完全一致
#    (APPS / PACKAGES 双引号换行包裹 + INTERVAL / LOG_ENABLED /
#     WHITELIST / CLEAN_ON_BOOT)。
#  - 不再创建 a11y_keepalive_apps.txt(列表已并入 conf 的 APPS)。
#  - 不再为 busybox/bin 里的旧脚本设权限(新架构已不依赖它们)。
# ============================================================

timer_start=$(date "+%Y-%m-%d %H:%M:%S")

LogPrint() {
	echo "$1"
}

# grep_prop: 从 module.prop 读取键值(Magisk/KernelSU 安装器通常已提供,
# 这里做个兜底, 避免个别管理器没注入)
if ! command -v grep_prop >/dev/null 2>&1; then
	grep_prop() {
		local REGEX="s/^$1=//p"
		shift
		local FILES="$@"
		[ -z "$FILES" ] && FILES='/system/build.prop'
		sed -n "$REGEX" $FILES 2>/dev/null | head -n 1
	}
fi

model="$(grep_prop ro.product.system.model)"
android_version="$(grep_prop ro.build.version.release)"
version="$(grep_prop version "${MODPATH}/module.prop")"
versioncode="$(grep_prop versionCode "${MODPATH}/module.prop")"
name="$(grep_prop name "${MODPATH}/module.prop")"
description="$(grep_prop description "${MODPATH}/module.prop")"

cat <<EOF
- 设备型号: ${model}
- Android 版本: ${android_version}
- 模块名称: ${name}
- 模块版本: ${version} (${versioncode})
- 作者: Operit
- ${description}
- 安装时间: ${timer_start}
EOF

# ---------- 1. 设置脚本权限 ----------
LogPrint "- 设置脚本权限(1/3)"
for file in service.sh action.sh uninstall.sh config/Function.sh config/Monitor.sh; do
	if [ -f "${MODPATH}/${file}" ]; then
		set_perm "${MODPATH}/${file}" 0 0 0755
	fi
done

# WebUI 目录权限(浏览器要能读取)
if [ -d "${MODPATH}/webroot" ]; then
	set_perm_recursive "${MODPATH}/webroot" 0 0 0755 0644
fi

# ---------- 2. 创建外部配置与日志目录 ----------
LogPrint "- 创建外部配置与日志目录(2/3)"
mkdir -p /data/media/0/Android
chmod 0777 /data/media/0/Android >/dev/null 2>&1
chown media_rw:media_rw /data/media/0/Android >/dev/null 2>&1

CONF="/data/media/0/Android/a11y_keepalive.conf"
LOG="/data/media/0/Android/a11y_keepalive.log"

if [ ! -f "${CONF}" ]; then
	cat <<'CONF' > "${CONF}"
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
"

# 附加包名(旧版兼容项，功能同 APPS)
PACKAGES="
"

# 检查周期(秒)。越小恢复越快，越耗电。
# 推荐 15~60。低于 5 会被强制修正为 5。
INTERVAL=20

# 日志开关 (1=开启 0=关闭)
LOG_ENABLED=1

# 是否把保活 APP 加入电池优化白名单 (1=是 0=否)
WHITELIST=1

# 开机时是否先清空所有无障碍开关再重新开启(1=是 0=否)
# 0 更安全，不会影响 APPS 之外的应用
CLEAN_ON_BOOT=0

CONF
	LogPrint "- 已创建默认配置 ${CONF}"
else
	LogPrint "- 检测到已有配置，保留原配置"
fi

chmod 0664 "${CONF}" >/dev/null 2>&1
chown media_rw:media_rw "${CONF}" >/dev/null 2>&1

# 日志文件
touch "${LOG}" >/dev/null 2>&1
chmod 0664 "${LOG}" >/dev/null 2>&1
chown media_rw:media_rw "${LOG}" >/dev/null 2>&1

# ---------- 3. 初始化运行状态 ----------
LogPrint "- 初始化运行状态(3/3)"
echo "A11y KeepAlive：等待重启" > "/data/media/0/Android/a11y_keepalive.state" 2>/dev/null
chmod 0664 "/data/media/0/Android/a11y_keepalive.state" >/dev/null 2>&1

LogPrint "- 配置文件: ${CONF}"
LogPrint "- 日志文件: ${LOG}"
LogPrint "- 安装完成后请重启设备"
LogPrint "- 重启后可通过模块 WebUI 或动作按钮管理"
exit 0
