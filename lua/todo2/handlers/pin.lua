-- lua/todo2/handlers/pin.lua
-- 搁置（pinned）：把「知道存在、但现在不动」的标记收起来。
--
-- 语义边界：搁置是**收纳**，不是状态、不写进 TODO 行、不改变任何时间字段。
-- 它只影响抽屉的呈现（⚑ 徽章 + 同级排最后），不影响日历、过滤与统计 ——
-- 否则它会变成一种「看不见的隐藏态」，比不搁置更糟。

local M = {}

local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")

--- 切换搁置状态。
---@param id string 任务ID
---@param on_done? fun() 写入后的回调（属性面板用来原地刷新）
---@return boolean 是否成功
function M.pin_for_id(id, on_done)
	local task = core.get_task(id)
	if not task then
		vim.notify("todo2: task not found", vim.log.levels.ERROR)
		return false
	end

	local target = task.core.pinned ~= true
	if not core.set_pinned(id, target) then
		vim.notify("todo2: could not update the pinned flag", vim.log.levels.ERROR)
		return false
	end

	vim.notify(target and "todo2: pinned (shelved, sorted last)" or "todo2: unpinned", vim.log.levels.INFO)
	if on_done then
		on_done()
	end
	return true
end

--- `:TodoPin`：光标所在任务（或选择器里选一个）切换搁置。
---@return boolean 是否成功
function M.pin_cmd()
	return picker.pick(function(task)
		return M.pin_for_id(task.id, function()
			local loc = task.locations and task.locations.todo
			if loc and loc.path and loc.line then
				require("todo2.render.todo_render").render_task_by_line(loc.path, loc.line)
			end
			pcall(function()
				require("todo2.ui.drawer").render()
			end)
		end)
	end)
end

return M
