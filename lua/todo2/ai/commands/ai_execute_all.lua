-- lua/todo2/ai/commands/ai_execute_all.lua
-- 批量执行当前文件所有 AI 可执行任务（不依赖 locator）

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")
local executor = require("todo2.ai.executor")
local events = require("todo2.core.events") -- ⭐ 引入 events

---------------------------------------------------------------------
-- 获取当前文件所有 TODO 任务 ID
---------------------------------------------------------------------
local function get_all_todo_ids_in_current_file()
	local path = vim.fn.expand("%:p")
	local ns = "todo.index.file_to_todo"
	local ids = index._get_ids_by_file(ns, path)
	return ids or {}
end

---------------------------------------------------------------------
-- 执行所有 AI 可执行任务
---------------------------------------------------------------------
function M.execute_all()
	local ids = get_all_todo_ids_in_current_file()
	if #ids == 0 then
		vim.notify("当前文件没有任何 TODO 任务", vim.log.levels.WARN)
		return
	end

	local ai_tasks = {}
	local executed_ids = {}
	for _, id in ipairs(ids) do
		local todo = link.get_todo(id, { force_relocate = true })
		if todo and todo.ai_executable then
			table.insert(ai_tasks, todo)
		end
	end

	if #ai_tasks == 0 then
		vim.notify("当前文件没有 AI 可执行任务（请先 :Todo2AIToggle）", vim.log.levels.WARN)
		return
	end

	table.sort(ai_tasks, function(a, b)
		return a.line < b.line
	end)

	vim.notify("开始执行 " .. #ai_tasks .. " 个 AI 任务...", vim.log.levels.INFO)

	local success_count = 0
	for _, todo in ipairs(ai_tasks) do
		local result = executor.execute(todo.id)

		if not result.ok then
			vim.notify(
				"任务 " .. todo.id .. " 执行失败: " .. (result.error or "未知错误"),
				vim.log.levels.ERROR
			)
		else
			table.insert(executed_ids, todo.id)
			success_count = success_count + 1
			vim.notify("任务 " .. todo.id .. " 已完成", vim.log.levels.INFO)
		end
	end

	-- ⭐ 统一触发事件刷新
	if #executed_ids > 0 then
		events.on_state_changed({
			source = "ai_execute_all",
			ids = executed_ids,
			-- events 会自动补全 files
		})
	end

	vim.notify(string.format("AI 任务执行完毕: %d/%d 成功", success_count, #ai_tasks), vim.log.levels.INFO)
end

return M
