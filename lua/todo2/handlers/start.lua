-- lua/todo2/handlers/start.lua
-- 开始日（`~YYYY-MM-DD`）的对外门面。实现全在 handlers/datefield.lua。
--
--   :TodoStart [date]  设置开始日（无参数则弹日期面板）
--   :TodoStart none    清除开始日（任务退回「只有期限」或「纯标记」）
--
-- 有 start 无 due = 计划；start + due = 排期；两个都没有 = 代码地图里的标记。

local api = require("todo2.handlers.datefield").api("start")

return {
	--- :TodoStart 命令实现。
	start_cmd = api.cmd,
	--- 按任务 id 直接写开始日；`value == ""` 表示清除。
	set_start_for_id = api.set_for_id,
	--- 按任务 id 打开开始日输入入口。
	start_for_id = api.for_id,
}
