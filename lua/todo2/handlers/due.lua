-- lua/todo2/handlers/due.lua
-- 到期日（`@YYYY-MM-DD`）命令入口。实现都在 handlers/datefield.lua，
-- 这里保留到期日专用的薄门面，避免调用方关心字段参数。
--
--   :TodoDue [date]  给光标处任务设置到期日（无参数则弹日期面板）
--   :TodoDue none    清除到期日
--
-- date 支持：YYYY-MM-DD / YYYY/MM/DD / YYYYMMDD / today / tomorrow / +Nd / -Nd

local M = {}

local datefield = require("todo2.handlers.datefield")

--- :TodoDue 命令实现。
---@param args? table
function M.due_cmd(args)
	datefield.cmd("due", args)
end

--- 按任务 id 直接写到期日（不弹输入框）；`value == ""` 表示清除。
---@param id string
---@param value string
---@return boolean ok
function M.set_due_for_id(id, value)
	return datefield.set_by_id("due", id, value)
end

--- 按任务 id 打开到期日输入入口（供抽屉/属性面板复用）。
---@param id string|nil
---@param value? string 命令行传入的日期（省略则弹面板）
---@param on_done? fun()
function M.due_for_id(id, value, on_done)
	datefield.for_id("due", id, value, on_done)
end

--- 一行表达式输入（不弹三格面板）。
---@param id string
---@param current string|nil
---@param on_done? fun()
function M.prompt_expression(id, current, on_done)
	datefield.prompt_expression("due", id, current, on_done)
end

return M
