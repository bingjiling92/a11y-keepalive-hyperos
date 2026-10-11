"use strict";

/* ============================================================
 * KernelSU WebUI 桥接层（内联版 kernelsu npm 的 exec 实现）
 *
 * 说明：KernelSU 并不提供全局 exec() 函数！
 * 官方做法是 `import { exec } from 'kernelsu'`（需要打包）。
 * 管理器实际注入的是全局对象 `ksu`，原型为：
 *   ksu.exec(command, JSON.stringify(options), callbackName)
 *   完成后回调 window[callbackName](errno, stdout, stderr)
 * 下面把官方 npm 包的 exec 实现直接内联，免去打包步骤。
 * ============================================================ */

var hasKsu = (typeof ksu !== "undefined" && ksu && typeof ksu.exec === "function");

var _cbSeq = 0;
function _cbName(prefix){
  _cbSeq++;
  return prefix + "_cb_" + Date.now() + "_" + _cbSeq;
}

function exec(command, options){
  if (!hasKsu){
    return Promise.reject(new Error("KernelSU WebUI 环境不可用"));
  }
  if (typeof options === "undefined") options = {};
  return new Promise(function(resolve, reject){
    var name = _cbName("exec");
    window[name] = function(errno, stdout, stderr){
      resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
      try { delete window[name]; } catch(e){ window[name] = undefined; }
    };
    try {
      ksu.exec(command, JSON.stringify(options), name);
    } catch (err) {
      try { delete window[name]; } catch(e){}
      reject(err);
    }
  });
}

function ksuToast(msg){
  if (hasKsu && typeof ksu.toast === "function"){
    try { ksu.toast(msg); return; } catch(e){}
  }
  toast(msg);
}

/* ============================================================
 * 路径常量（与 shell 侧保持一致）
 * ============================================================ */
var MODDIR = "/data/adb/modules/a11y_keepalive_v2";
var CONF   = "/data/media/0/Android/a11y_keepalive.conf";
var LOG    = "/data/media/0/Android/a11y_keepalive.log";
var STATE  = "/data/media/0/Android/a11y_keepalive.state";

/* ============================================================
 * 基础工具
 * ============================================================ */
function $(id){ return document.getElementById(id); }

function toast(msg, ms){
  var t = $("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(t._h);
  t._h = setTimeout(function(){ t.classList.remove("show"); }, ms || 2400);
}

function busy(on){ $("mask").classList.toggle("show", !!on); }

function shq(s){ return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

async function run(cmd){
  try{
    var r = await exec(cmd);
    // 官方语义：errno === 0 表示成功
    return { ok: (r.errno === 0), out: (r.stdout + r.stderr) || "" };
  }catch(e){
    return { ok:false, out:"命令执行失败: " + (e && e.message ? e.message : String(e)) };
  }
}

/* ============================================================
 * 状态
 * ============================================================ */
async function refreshStatus(){
  var r = await run("sh " + shq(MODDIR + "/action.sh") + " status");
  var out = (r.out || "").trim();
  var running = (out.indexOf("running") !== -1);

  var dot = $("dot"), txt = $("statusText"), sw = $("sw");
  if (running){
    dot.className = "dot on";
    txt.textContent = "保活运行中";
    sw.checked = true;
  } else {
    dot.className = "dot off";
    txt.textContent = "保活已停止";
    sw.checked = false;
  }

  var st = await run("sh " + shq(MODDIR + "/action.sh") + " state");
  var detail = (st.out || "").trim();
  $("statusSub").textContent = detail
    ? detail
    : (running ? "守护进程正在持续监测无障碍开关。" : "点击上方开关或“启动保活”开始。");
}

function onSwitch(){
  if ($("sw").checked) doStop();
  else doStart();
}

async function doStart(){
  if (!hasKsu){ toast("当前不在 KernelSU WebUI 环境中"); return; }
  busy(true);
  await run("sh " + shq(MODDIR + "/action.sh") + " start");
  busy(false);
  ksuToast("已启动保活");
  await refreshStatus();
}

async function doStop(){
  if (!hasKsu){ toast("当前不在 KernelSU WebUI 环境中"); return; }
  busy(true);
  await run("sh " + shq(MODDIR + "/action.sh") + " stop");
  busy(false);
  ksuToast("已停止保活");
  await refreshStatus();
}

/* ============================================================
 * 配置
 * ============================================================ */
function cfgGet(text, key, def){
  var m = text.match(new RegExp("^" + key + "=(.*)$", "m"));
  if (!m) return def;
  return m[1].replace(/^\s+|\s+$/g, "");
}

function numOnly(s, def){
  var v = String(s || "").replace(/[^0-9]/g, "");
  return v === "" ? def : v;
}

async function loadConfig(){
  var r = await run("cat " + shq(CONF) + " 2>/dev/null");
  var c = r.out || "";
  $("cfgInterval").value = numOnly(cfgGet(c, "INTERVAL", "20"), "20");
  $("cfgLog").value      = numOnly(cfgGet(c, "LOG_ENABLED", "1"), "1");
  $("cfgWl").value       = numOnly(cfgGet(c, "WHITELIST", "1"), "1");
}

async function saveConfig(){
  if (!hasKsu){ toast("当前不在 KernelSU WebUI 环境中"); return; }
  var iv = parseInt($("cfgInterval").value, 10);
  if (isNaN(iv) || iv < 5) iv = 20;
  if (iv > 3600) iv = 3600;
  var lg = ($("cfgLog").value === "0") ? "0" : "1";
  var wl = ($("cfgWl").value === "0") ? "0" : "1";

  busy(true);
  var cmd =
    "F=" + shq(CONF) + "; " +
    "[ -f \"$F\" ] || : > \"$F\"; " +
    "sed -i '/^INTERVAL=/d; /^LOG_ENABLED=/d; /^WHITELIST=/d' \"$F\" 2>/dev/null; " +
    "printf 'INTERVAL=%s\\nLOG_ENABLED=%s\\nWHITELIST=%s\\n' '" + iv + "' '" + lg + "' '" + wl + "' >> \"$F\"; " +
    "echo ok";
  var r = await run(cmd);
  if ((r.out || "").indexOf("ok") !== -1) {
    // 重启后立即读取新配置，不等待 INTERVAL。
    await run("sh " + shq(MODDIR + "/action.sh") + " restart");
    ksuToast("参数已保存并立即生效");
  } else {
    toast("保存失败：" + (r.out || "未知错误"));
  }
  busy(false);
  await refreshAll();
}

/* ============================================================
 * 应用列表
 * ============================================================ */
async function loadApps(){
  var r = await run("cat " + shq(CONF) + " 2>/dev/null");
  var c = r.out || "";
  var m = c.match(/^APPS="([\s\S]*?)"/m);
  var list = m ? m[1] : "";
  $("apps").value = list.replace(/^\s*\n/, "").replace(/\n\s*$/, "").replace(/^\s+|\s+$/g, "");
}

async function saveApps(){
  if (!hasKsu){ toast("当前不在 KernelSU WebUI 环境中"); return; }
  var raw = $("apps").value || "";
  var lines = raw.split(/\r?\n/).map(function(l){ return l.replace(/\s+/g, ""); });
  lines = lines.filter(function(l){ return l !== "" && l.charAt(0) !== "#"; });
  var body = lines.length ? "\n" + lines.join("\n") + "\n" : "";

  busy(true);
  var cmd =
    "F=" + shq(CONF) + "; " +
    "[ -f \"$F\" ] || : > \"$F\"; " +
    "sed -i '/^APPS=\"\"$/d' \"$F\" 2>/dev/null; " +
    "awk 'BEGIN{s=0} /^APPS=\"/{s=1;next} s==1 && /\"$/{s=0;next} s==1{next} {print}' \"$F\" > \"$F.tmp\" 2>/dev/null; " +
    "[ -f \"$F.tmp\" ] && mv -f \"$F.tmp\" \"$F\"; " +
    "printf 'APPS=\"%s\"\\n' " + shq(body) + " >> \"$F\"; " +
    "echo ok";
  var r = await run(cmd);
  if ((r.out || "").indexOf("ok") !== -1) {
    // 保存后立即重启守护进程，新服务在第一轮就写入 settings。
    var started = await run("sh " + shq(MODDIR + "/action.sh") + " restart");
    if ((started.out || "").indexOf("running") !== -1) ksuToast("应用列表已保存并立即生效");
    else toast("列表已保存，但守护进程启动失败，请查看日志");
  } else {
    toast("保存失败：" + (r.out || "未知错误"));
  }
  busy(false);
  await refreshAll();
}

/* ============================================================
 * 日志
 * ============================================================ */
async function loadLog(){
  var r = await run("tail -n 80 " + shq(LOG) + " 2>/dev/null");
  var out = (r.out || "").trim();
  $("logbox").textContent = out ? out : "暂无日志";
}

async function clearLog(){
  if (!hasKsu){ toast("当前不在 KernelSU WebUI 环境中"); return; }
  busy(true);
  await run(": > " + shq(LOG) + " 2>/dev/null");
  busy(false);
  ksuToast("日志已清空");
  await loadLog();
}

/* ============================================================
 * 启动
 * ============================================================ */
async function refreshAll(){
  await Promise.all([ refreshStatus(), loadConfig(), loadApps(), loadLog() ]);
}

(function init(){
  if (!hasKsu){
    $("envWarn").classList.add("show");
    $("statusText").textContent = "环境不可用";
    $("statusSub").textContent = "请通过 KernelSU / APatch 管理器打开本页面。";
    $("logbox").textContent = "无法连接到 KernelSU，shell 功能不可用。";
    return;
  }
  refreshAll();
  // 5 秒轮询状态即可，避免频繁执行 shell
  setInterval(refreshStatus, 5000);
})();