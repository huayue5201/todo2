-- lua/todo2/commands/ai_toggle.lua
-- 切换任务是否 AI 可执行（基于 line_analyzer，而不是 locator）

local M = {}

local link = require("todo2.store.link")
local events = require("todo2.core.events") -- ⭐ 引入 events
local line_analyzer = require("todo2.utils.line_analyzer")

---------------------------------------------------------------------
-- 获取当前光标所在任务 ID（基于行分析，而不是 locator）
---------------------------------------------------------------------
local function get_current_task_id()
	local analysis = line_analyzer.analyze_current_line()
	if not analysis then
		return nil
	end

	-- TODO 文件任务行
	if analysis.is_todo_task and analysis.id then
		return analysis.id
	end

	-- CODE 文件标记行
	if analysis.is_code_mark and analysis.id then
		return analysis.id
	end

	return nil
end

---------------------------------------------------------------------
-- 切换 AI 可执行状态（不写入文件，只更新存储 + 渲染）
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

	-- 切换字段
	local updated = vim.deepcopy(todo)
	updated.ai_executable = not todo.ai_executable

	-- 写回存储层（自动同步 CODE）
	link.update_todo(id, updated)

	-- 通知
	if updated.ai_executable then
		vim.notify("已启用 AI 执行: " .. id, vim.log.levels.INFO)
	else
		vim.notify("已关闭 AI 执行: " .. id, vim.log.levels.INFO)
	end

	-----------------------------------------------------------------
	-- ⭐ 触发事件刷新（统一由 events 处理）
	-----------------------------------------------------------------
	events.on_state_changed({
		source = "ai_toggle",
		ids = { id },
		-- events 会自动补全 files
	})
end

return M
