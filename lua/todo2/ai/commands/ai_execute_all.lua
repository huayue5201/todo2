-- lua/todo2/ai/commands/ai_execute_all.lua
-- 批量执行当前文件所有 AI 可执行任务

local M = {}

-- FIX:ref:f8fa75
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local executor = require("todo2.ai.executor")
local events = require("todo2.core.events")

local listener_group = vim.api.nvim_create_augroup("Todo2AIBatch_" .. os.time(), { clear = true })

vim.api.nvim_create_autocmd("User", {
	pattern = "Todo2AITaskComplete",
	group = listener_group,
	callback = function(args)
		local id = args.data.id
		local success = args.data.data and args.data.data.success

		-- 处理任务完成
		on_task_complete(id, success)

		-- 所有任务完成后清理监听
		if pending_count == 0 then
			vim.api.nvim_del_augroup_by_id(listener_group)
		end
	end,
})

---------------------------------------------------------------------
-- 获取当前文件所有 TODO 任务
---------------------------------------------------------------------
local function get_all_todo_tasks_in_current_file()
	local path = vim.fn.expand("%:p")
	local todo_links = index.find_todo_links_by_file(path)

	local ids = {}
	for _, link in ipairs(todo_links) do
		table.insert(ids, link.id)
	end

	return ids, todo_links
end

---------------------------------------------------------------------
-- 从任务构造兼容的 link 对象
---------------------------------------------------------------------
local function task_to_link(task)
	if not task then
		return nil
	end

	return {
		id = task.id,
		path = task.locations.todo and task.locations.todo.path,
		line = task.locations.todo and task.locations.todo.line,
		content = task.core.content,
		tag = task.core.tags[1],
		status = task.core.status,
		ai_executable = task.core.ai_executable,
	}
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
		local task = core.get_task(todo_link.id)
		if task and task.core.ai_executable then
			local link = task_to_link(task)
			if link then
				table.insert(ai_tasks, {
					id = todo_link.id,
					line = link.line or 1,
					task = task,
				})
			end
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
	local failed_count = 0
	local pending_count = #ai_tasks

	-- 任务状态跟踪
	local task_status = {}
	for _, item in ipairs(ai_tasks) do
		task_status[item.id] = "pending"
	end

	-- ⭐ 完成回调
	local function on_task_complete(id, success)
		if task_status[id] ~= "pending" then
			return
		end

		task_status[id] = success and "success" or "failed"

		if success then
			table.insert(executed_ids, id)
			success_count = success_count + 1
		else
			failed_count = failed_count + 1
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

			local level = failed_count == 0 and vim.log.levels.INFO or vim.log.levels.WARN
			vim.notify(string.format("AI 任务执行完毕: %d成功, %d失败", success_count, failed_count), level)
		end
	end

	-- ⭐ 启动所有任务（使用增强版 executor.run_stream）
	for _, item in ipairs(ai_tasks) do
		local result = executor.run_stream(item.id, {
			on_done = on_task_complete, -- 传入回调
		})

		if not result.ok then
			-- 启动失败
			vim.notify(
				"任务 " .. item.id:sub(1, 6) .. " 启动失败: " .. (result.error or "未知错误"),
				vim.log.levels.ERROR
			)
			on_task_complete(item.id, false)
		else
			vim.notify("任务 " .. item.id:sub(1, 6) .. " 已启动", vim.log.levels.DEBUG)
		end
	end
end

return M
