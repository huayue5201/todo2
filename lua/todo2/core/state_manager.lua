-- lua/todo2/core/state_manager.lua
-- 纯功能平移：使用新接口获取任务状态

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core") -- 改为 core
local events = require("todo2.core.events")
local scheduler = require("todo2.render.scheduler")
local autosave = require("todo2.core.autosave")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = scheduler.get_file_lines(vim.api.nvim_buf_get_name(bufnr))[lnum]
	if not line then
		return false
	end

	local start_col, end_col = format.get_checkbox_position(line)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

---------------------------------------------------------------------
-- 普通任务切换
---------------------------------------------------------------------
local function toggle_normal_task(bufnr, lnum, task)
	local line = scheduler.get_file_lines(vim.api.nvim_buf_get_name(bufnr))[lnum]
	if not line then
		return false
	end

	local current_checkbox = task.checkbox or "[ ]"
	local new_checkbox = (current_checkbox == "[ ]") and "[x]" or "[ ]"

	local success = replace_status(bufnr, lnum, current_checkbox, new_checkbox)
	if success then
		task.status = (new_checkbox == "[x]") and "completed" or "normal"
		task.checkbox = new_checkbox
	end
	return success
end

---------------------------------------------------------------------
-- 收集所有子任务节点
---------------------------------------------------------------------
local function collect_all_child_nodes(task, result)
	result = result or {}
	table.insert(result, task)
	if task.children then
		for _, child in ipairs(task.children) do
			collect_all_child_nodes(child, result)
		end
	end
	return result
end

---------------------------------------------------------------------
-- 批量切换普通任务
---------------------------------------------------------------------
local function batch_toggle_normal_tasks(root_task, bufnr, target_status)
	local all_nodes = collect_all_child_nodes(root_task, {})
	table.sort(all_nodes, function(a, b)
		return a.line_num > b.line_num
	end)

	local updated = 0
	local target_checkbox = (target_status == "completed") and "[x]" or "[ ]"

	for _, node in ipairs(all_nodes) do
		local line = scheduler.get_file_lines(vim.api.nvim_buf_get_name(bufnr))[node.line_num]
		if line then
			local current_checkbox = node.checkbox or "[ ]"
			if replace_status(bufnr, node.line_num, current_checkbox, target_checkbox) then
				node.status = target_status
				node.checkbox = target_checkbox
				updated = updated + 1
			end
		end
	end

	return { updated = updated, ids = {}, success = updated > 0 }
end

---------------------------------------------------------------------
-- 收集所有子任务 ID（双链任务）
---------------------------------------------------------------------
local function collect_all_child_ids(task, result)
	result = result or {}
	if task.id then
		result[task.id] = true
	end
	if task.children then
		for _, child in ipairs(task.children) do
			collect_all_child_ids(child, result)
		end
	end
	return result
end

---------------------------------------------------------------------
-- 批量更新存储（使用新接口）
---------------------------------------------------------------------
local function batch_update_storage(ids, target_status)
	local id_list = vim.tbl_keys(ids)
	local result = { success = 0, failed = 0 }

	for _, id in ipairs(id_list) do
		local task = core.get_task(id)
		if task then
			if target_status == types.STATUS.COMPLETED then
				task.core.previous_status = task.core.status
				task.core.status = types.STATUS.COMPLETED
				task.timestamps.completed = os.time()
			else
				if types.is_completed_status(task.core.status) then
					task.core.status = task.core.previous_status or types.STATUS.NORMAL
					task.core.previous_status = nil
					task.timestamps.completed = nil
				else
					task.core.status = target_status
				end
			end
			task.timestamps.updated = os.time()

			core.save_task(id, task)
			result.success = result.success + 1
		else
			result.failed = result.failed + 1
		end
	end

	return result
end

---------------------------------------------------------------------
-- 批量切换双链任务
---------------------------------------------------------------------
local function batch_toggle_linked_tasks(root_task, bufnr, target_status)
	local all_ids = collect_all_child_ids(root_task, {})
	local update_result = batch_update_storage(all_ids, target_status)

	local current_checkbox = types.status_to_checkbox(root_task.status)
	local target_checkbox = types.status_to_checkbox(target_status)
	local success = replace_status(bufnr, root_task.line_num, current_checkbox, target_checkbox)

	if success then
		root_task.status = target_status
	end

	return {
		updated = update_result.success,
		ids = vim.tbl_keys(all_ids),
		success = success,
	}
end

---------------------------------------------------------------------
-- 主切换函数
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	local tasks, roots, id_to_task = scheduler.get_tasks_for_buf(bufnr, { force_refresh = true })

	local current_task = nil
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "不是任务行"
	end

	-- 普通任务
	if not current_task.id then
		local success = toggle_normal_task(bufnr, lnum, current_task)
		if success then
			if not opts.skip_write then
				autosave.request_save(bufnr)
			end

			events.on_state_changed({
				source = "state_manager",
				ids = {},
				files = { path },
				file = path,
				bufnr = bufnr,
				timestamp = os.time() * 1000,
			})

			return true, "normal_toggled"
		end
		return false, "切换失败"
	end

	-- 双链任务：从内部格式获取状态
	local task = core.get_task(current_task.id)
	if task then
		current_task.status = task.core.status
		current_task.previous_status = task.core.previous_status
	end

	if current_task.status == types.STATUS.ARCHIVED then
		return false, "归档任务不能切换状态"
	end

	local target_status = types.is_active_status(current_task.status) and types.STATUS.COMPLETED
		or (current_task.previous_status or types.STATUS.NORMAL)

	local result = batch_toggle_linked_tasks(current_task, bufnr, target_status)
	if not result.success then
		return false, "切换失败"
	end

	local affected_files = { path }
	for _, id in ipairs(result.ids) do
		local t = core.get_task(id)
		if
			t
			and t.locations.code
			and t.locations.code.path
			and not vim.tbl_contains(affected_files, t.locations.code.path)
		then
			table.insert(affected_files, t.locations.code.path)
		end
	end

	events.on_state_changed({
		source = "state_manager",
		ids = result.ids,
		files = affected_files,
		file = path,
		bufnr = bufnr,
		timestamp = os.time() * 1000,
	})

	if not opts.skip_write then
		autosave.request_save(bufnr)
	end

	return true, target_status
end

return M
