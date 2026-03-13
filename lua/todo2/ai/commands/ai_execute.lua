-- lua/todo2/ai/commands/ai_execute.lua
-- 执行当前任务（流式执行版）

local M = {}

local executor = require("todo2.ai.executor")
local link = require("todo2.store.link")
local events = require("todo2.core.events")
local line_analyzer = require("todo2.utils.line_analyzer")

---------------------------------------------------------------------
-- 获取当前光标所在任务ID
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
-- ⭐ 执行AI任务（流式执行，不阻塞）
---------------------------------------------------------------------
function M.execute()
	local id = get_current_task_id()
	if not id then
		vim.notify("未找到任务（光标不在TODO/CODE行）", vim.log.levels.WARN)
		return
	end

	local todo = link.get_todo(id, { force_relocate = true })
	if not todo then
		vim.notify("任务不存在: " .. id, vim.log.levels.ERROR)
		return
	end

	if not todo.ai_executable then
		vim.notify("该任务未标记为AI可执行（请先:Todo2AIToggle）", vim.log.levels.WARN)
		return
	end

	vim.notify("AI正在流式执行任务: " .. id .. " ...", vim.log.levels.INFO)

	-- 调用流式执行（异步，不阻塞）
	local result = executor.run_stream(id)

	if not result.ok then
		vim.notify("AI流式执行失败: " .. (result.error or "未知错误"), vim.log.levels.ERROR)
		return
	end

	-- 异步任务，等待完成回调
	vim.notify("AI流式生成已启动，结果将实时写入...", vim.log.levels.INFO)
end

return M
