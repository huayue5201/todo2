-- lua/todo2/handlers/start.lua
-- 开始日（`~YYYY-MM-DD`）命令入口。实现都在 handlers/datefield.lua。
--
--   :TodoStart [date]  设置开始日（无参数则弹日期面板）
--   :TodoStart none    清除开始日（任务退回「只有期限」或「纯标记」）
--
-- 有 start 无 due = 计划；start + due = 排期；两个都没有 = 代码地图里的标记。

local M = {}

local datefield = require("todo2.handlers.datefield")

--- :TodoStart 命令实现。
---@param args? table
function M.start_cmd(args)
	datefield.cmd("start", args)
end

--- 按任务 id 直接写开始日（不弹输入框）；`value == ""` 表示清除。
---@param id string
---@param value string
---@return boolean ok
function M.set_start_for_id(id, value)
	return datefield.set_by_id("start", id, value)
end

--- 按任务 id 打开开始日输入入口。
---@param id string|nil
---@param value? string
---@param on_done? fun()
function M.start_for_id(id, value, on_done)
	datefield.for_id("start", id, value, on_done)
end

return M
