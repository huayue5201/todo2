-- lua/todo2/ai/commands/ai_execute_all.lua

local M = {}

local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local executor = require("todo2.ai.executor")
local events = require("todo2.core.events")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 获取当前代码文件中所有符合条件的任务 ID
---------------------------------------------------------------------
local function get_eligible_task_ids()
	local raw_path = vim.fn.expand("%:p")
	local normalized_path = file.normalize_path(raw_path)

	-- 尝试两种方式获取
	local code_links_1 = index.find_code_links_by_file(raw_path) or {}
	local code_links_2 = index.find_code_links_by_file(normalized_path) or {}

	-- 使用找到的那个
	local code_links = #code_links_2 > 0 and code_links_2 or code_links_1

	local eligible_ids = {}

	for _, link in ipairs(code_links) do
		local task = core.get_task(link.id)
		if not task then
			goto continue
		end

		if not task.core.ai_executable then
			goto continue
		end

		if types.is_completed_status(task.core.status) then
			goto continue
		end

		table.insert(eligible_ids, link.id)

		::continue::
	end

	return eligible_ids
end

---------------------------------------------------------------------
-- 执行所有符合条件的任务
---------------------------------------------------------------------
function M.execute_all()
	local ids = get_eligible_task_ids()

	if #ids == 0 then
		vim.notify("当前代码文件没有 AI 可执行任务", vim.log.levels.WARN)
		return
	end

	vim.notify(string.format("开始执行 %d 个 AI 任务...", #ids), vim.log.levels.INFO)

	local success_count = 0
	local failed_count = 0
	local pending_count = #ids

	local task_status = {}
	for _, id in ipairs(ids) do
		task_status[id] = "pending"
	end

	local function on_task_complete(id, success)
		if task_status[id] ~= "pending" then
			return
		end

		task_status[id] = success and "success" or "failed"

		if success then
			success_count = success_count + 1
		else
			failed_count = failed_count + 1
		end

		pending_count = pending_count - 1

		if pending_count == 0 then
			local msg = string.format("批量执行完成: %d 成功, %d 失败", success_count, failed_count)
			vim.notify(msg, failed_count == 0 and vim.log.levels.INFO or vim.log.levels.WARN)

			if success_count > 0 then
				local success_ids = {}
				for id, status in pairs(task_status) do
					if status == "success" then
						table.insert(success_ids, id)
					end
				end
				events.on_state_changed({
					source = "ai_execute_all",
					ids = success_ids,
				})
			end
		end
	end

	for _, id in ipairs(ids) do
		local result = executor.run_stream(id, {
			on_done = on_task_complete,
		})

		if not result.ok then
			on_task_complete(id, false)
		end
	end
end

return M
