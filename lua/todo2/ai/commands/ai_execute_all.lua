-- lua/todo2/ai/commands/ai_execute_all.lua
-- 批量执行当前文件所有 AI 可执行任务

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")
local executor = require("todo2.ai.executor")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 获取当前文件所有 TODO 任务（修复版）
---------------------------------------------------------------------
local function get_all_todo_tasks_in_current_file()
	local path = vim.fn.expand("%:p")

	-- 使用 index.find_todo_links_by_file 获取所有 TODO 链接
	local todo_links = index.find_todo_links_by_file(path)

	-- 提取 ID
	local ids = {}
	for _, link in ipairs(todo_links) do
		table.insert(ids, link.id)
	end

	return ids, todo_links
end

---------------------------------------------------------------------
-- 执行所有 AI 可执行任务
---------------------------------------------------------------------
function M.execute_all()
	local ids, todo_links = get_all_todo_tasks_in_current_file()

	if #ids == 0 then
		vim.notify("当前文件没有任何 TODO 任务", vim.log.levels.WARN)
		return
	end

	-- 过滤出 AI 可执行的任务
	local ai_tasks = {}
	for _, todo_link in ipairs(todo_links) do
		-- 通过 link.get_todo 获取完整任务信息
		local todo = link.get_todo(todo_link.id, { force_relocate = true })
		if todo and todo.ai_executable then
			table.insert(ai_tasks, todo)
		end
	end

	if #ai_tasks == 0 then
		vim.notify("当前文件没有 AI 可执行任务（请先 :Todo2AIToggle）", vim.log.levels.WARN)
		return
	end

	-- 按行号排序
	table.sort(ai_tasks, function(a, b)
		return a.line < b.line
	end)

	vim.notify("开始执行 " .. #ai_tasks .. " 个 AI 任务...", vim.log.levels.INFO)

	local executed_ids = {}
	local success_count = 0
	local pending_count = #ai_tasks

	-- 为每个任务创建完成回调
	local function on_task_complete(id, success)
		if success then
			table.insert(executed_ids, id)
			success_count = success_count + 1
		end

		pending_count = pending_count - 1

		if pending_count == 0 then
			-- 所有任务完成
			if #executed_ids > 0 then
				events.on_state_changed({
					source = "ai_execute_all",
					ids = executed_ids,
				})
			end
			vim.notify(
				string.format("AI 任务执行完毕: %d/%d 成功", success_count, #ai_tasks),
				vim.log.levels.INFO
			)
		end
	end

	-- 启动所有任务
	for _, todo in ipairs(ai_tasks) do
		-- 包装回调
		local original_on_done = function()
			on_task_complete(todo.id, true)
		end

		-- 需要修改 executor.run_stream 以支持传入自定义 on_done
		-- 或者使用事件系统监听任务完成
		local result = executor.run_stream(todo.id)

		if not result.ok then
			vim.notify(
				"任务 " .. todo.id .. " 启动失败: " .. (result.error or "未知错误"),
				vim.log.levels.ERROR
			)
			on_task_complete(todo.id, false)
		else
			-- 成功启动的任务会在完成时通过 executor 内部的 on_done 回调
			-- 这里需要确保 executor.run_stream 内部会调用传入的 on_done
			vim.notify("任务 " .. todo.id .. " 已启动", vim.log.levels.DEBUG)
		end
	end
end

return M
