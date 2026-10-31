-- lua/todo2/handlers/due.lua
-- 到期日（`@YYYY-MM-DD`）的对外门面。实现全在 handlers/datefield.lua，
-- 这里只把同一套实现按「due」字段绑定一次，命令与调用方都不需要传字段名。
--
--   :TodoDue [date]  给光标处任务设置到期日（无参数则弹日期面板）
--   :TodoDue none    清除到期日
--
-- date 支持：YYYY-MM-DD / YYYY/MM/DD / YYYYMMDD / today / tomorrow / +Nd / -Nd

local api = require("todo2.handlers.datefield").api("due")

return {
	--- :TodoDue 命令实现。
	due_cmd = api.cmd,
	--- 按任务 id 直接写到期日（不弹输入框）；`value == ""` 表示清除。
	set_due_for_id = api.set_for_id,
	--- 按任务 id 打开到期日输入入口（抽屉 / 属性面板复用）。
	due_for_id = api.for_id,
}
