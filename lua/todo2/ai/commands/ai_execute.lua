-- lua/todo2/ai/commands/ai_execute.lua
-- 执行当前任务的 AI 代码生成（不依赖 locator）

local M = {}

local executor = require("todo2.ai.executor")
local link = require("todo2.store.link")
local events = require("todo2.core.events") -- ⭐ 引入 events
local line_analyzer = require("todo2.utils.line_analyzer")

---------------------------------------------------------------------
-- 获取当前光标所在任务 ID（基于行分析）
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
-- 执行 AI 任务
---------------------------------------------------------------------
function M.execute()
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

	if not todo.ai_executable then
		vim.notify("该任务未标记为 AI 可执行（请先 :Todo2AIToggle）", vim.log.levels.WARN)
		return
	end

	vim.notify("AI 正在执行任务: " .. id .. " ...", vim.log.levels.INFO)

	local result = executor.execute(id)

	if not result.ok then
		vim.notify("AI 执行失败: " .. (result.error or "未知错误"), vim.log.levels.ERROR)
		return
	end

	-- ⭐ 触发事件刷新
	events.on_state_changed({
		source = "ai_execute",
		ids = { id },
		-- events 会自动补全 files
	})

	vim.notify("AI 已生成代码并写回 CODE 标记", vim.log.levels.INFO)
end

return M
