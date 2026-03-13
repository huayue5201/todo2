-- lua/todo2/ai/commands/ai_toggle.lua
-- 切换任务是否 AI 可执行（基于 line_analyzer）

local M = {}

local link = require("todo2.store.link")
local events = require("todo2.core.events")
local line_analyzer = require("todo2.utils.line_analyzer")

---------------------------------------------------------------------
-- 获取当前光标所在任务 ID
---------------------------------------------------------------------
local function get_current_task_id()
	local analysis = line_analyzer.analyze_current_line()
	if not analysis then
		return nil
	end

	if analysis.is_todo_task and analysis.id then
		return analysis.id
	end

	if analysis.is_code_mark and analysis.id then
		return analysis.id
	end

	return nil
end

---------------------------------------------------------------------
-- 切换 AI 可执行状态
---------------------------------------------------------------------
function M.toggle()
	local id = get_current_task_id()
	if not id then
		vim.notify("未找到任务（光标不在 TODO/CODE 行）", vim.log.levels.WARN)
		return
	end

	local todo = link.get_todo(id, { force_relocate = true })
	if not todo then
		vim.notify("任务不存在: " .. id, vim.log.levels.ERROR)
		return
	end

	local updated = vim.deepcopy(todo)
	updated.ai_executable = not todo.ai_executable

	link.update_todo(id, updated)

	if updated.ai_executable then
		vim.notify("已启用 AI 执行: " .. id, vim.log.levels.INFO)
	else
		vim.notify("已关闭 AI 执行: " .. id, vim.log.levels.INFO)
	end

	events.on_state_changed({
		source = "ai_toggle",
		ids = { id },
	})
end

return M
