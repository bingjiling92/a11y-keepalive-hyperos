# A11y KeepAlive v3.2-fix（HyperOS 3.x 无障碍保活）

基于 Operit 的 A11y KeepAlive v3.1-hotfix 的修复版。持续保持指定应用的无障碍开关开启，对抗澎湃OS 3.x 无障碍强杀。

## v3.2 修复了什么（真机定位）
1. **"看起来在跑其实从不干活"（核心bug）**：v3.1 从 service.sh 拉起守护进程时，
   `Function.sh` 因 `DIR` 非空被跳过加载，而 shell 函数不能跨进程继承 →
   `write_EAST`/`mylog`/`load_config` 全是未定义命令，错误被 `>/dev/null` 吞掉。
   结果：状态/日志永不更新、开关被系统关掉后永远不恢复。**v3.2 改为无条件加载函数库。**
2. **被系统卡掉后永久失效**：新增独立看门狗（30s 检测），守护进程消失自动复活；
   心跳文件（每轮 touch）判定卡死并重启。
3. **写入路径**：状态/日志/配置从 `/data/media`(FUSE) 迁到 `/data/adb/a11y_keepalive`
   （原始 f2fs，任何上下文可写），旧配置开机自动迁移。
4. **dumpsys 加 timeout(10s)**：binder 卡死不再拖死整轮循环。
5. **目标 app 压 oom_score_adj(-800)**：app 被 LMK 杀掉是"失效"第一大根因，开关和进程一起保。
6. 修复 v3.2 开发中引入的 cur_EAST 误判（settings 返回冒号串 → 每轮误写库），
   改用 read_EAST_USER 按行拆分；状态文件改为内容变化才写，配合心跳判活。

## 真机验证（小米14 / HyperOS 3.0.307）
- 状态 `运行中(保护 2 个无障碍服务)`，日志只记真实恢复事件，无误报。
- user 0 与 user 999（分身）双空间开关均保持。
- 守护进程 oom_score_adj=-1000。

## 配置
`/data/adb/a11y_keepalive/a11y_keepalive.conf`：`APPS` 包名列表、`INTERVAL`(默认20s)、
`WHITELIST`(电池白名单)。WebUI 同旧版。
