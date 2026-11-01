-- lua/todo2/core/state_manager.lua
-- 纯数据驱动：双链任务不再操作 buffer；普通任务保持原语义

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local scheduler = require("todo2.render.scheduler")
local relation = require("todo2.store.task.relation")
local file = require("todo2.utils.file")
local status_domain = require("todo2.core.status")

---------------------------------------------------------------------
-- 工具函数：收集祖先/子孙 ID（统一由 relation 提供）
---------------------------------------------------------------------

local function to_set(ids)
	local set = {}
	for _, id in ipairs(ids) do
		set[id] = true
	end
	return set
end

local function collect_ancestors(task_ids)
	local ancestors = {}
	for id in pairs(task_ids) do
		for _, a in ipairs(relation.get_ancestor_ids(id)) do
			ancestors[a] = true
		end
	end
	return ancestors
end

local function collect_all_child_ids_from_store(task_id)
	return to_set(relation.get_subtree_ids(task_id))
end

---------------------------------------------------------------------
-- 普通任务（无 id）仍然需要改文本（保持原语义）
---------------------------------------------------------------------
local function toggle_normal_task(bufnr, lnum, task)
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = file.read_lines_smart(path)

	if not lines or lnum > #lines then
		return false
	end

	local line = lines[lnum]
	if not line then
		return false
	end

	local normal_cb = types.status_to_checkbox(status_domain.get_default())
	local done_cb = types.status_to_checkbox(types.STATUS.COMPLETED)

	local current_checkbox = task.checkbox or normal_cb
	local new_checkbox = (current_checkbox == normal_cb) and done_cb or normal_cb

	local start_col, end_col = format.get_checkbox_position(line)

	if not start_col or not end_col then
		return false
	end

	if start_col < 1 or end_col < 1 then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { new_checkbox })

	task.checkbox = new_checkbox
	task.status = types.checkbox_to_status(new_checkbox)

	return true
end

---------------------------------------------------------------------
-- 双链任务：批量更新存储（不操作 buffer）
---------------------------------------------------------------------
local function batch_update_storage(ids, target_status)
	local id_list = vim.tbl_keys(ids)
	local result = { success = 0, failed = 0 }

	for _, id in ipairs(id_list) do
		local task = core.get_task(id)
		if task then
			if target_status == types.STATUS.COMPLETED then
				status_domain.enter_terminal(task, types.STATUS.COMPLETED)
			elseif types.is_completed_status(task.core.status) then
				status_domain.exit_terminal(task)
			else
				task.core.status = target_status
				core.touch(task, "content")
			end

			core.save_task(id, task)
			result.success = result.success + 1
		else
			result.failed = result.failed + 1
		end
	end

	-- store 改完立刻写回行上的 checkbox / 标记：文件是终态真相源，
	-- 否则下一次 sync 会按 `[ ]` 把刚完成的任务打回活跃态。
	if result.success > 0 then
		local ok, task_line = pcall(require, "todo2.utils.task_line")
		if ok and task_line and task_line.rewrite_statuses then
			pcall(task_line.rewrite_statuses, id_list)
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 主切换函数（单行）
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	-----------------------------------------------------------------
	-- 情况 1：来自代码文件 → 通过 opts.id 切换（不操作 buffer）
	-----------------------------------------------------------------
	if opts.id then
		local task = core.get_task(opts.id)
		if not task then
			return false, "Task not found"
		end

		if task.core.status == types.STATUS.ARCHIVED then
			return false, "Archived tasks cannot change status"
		end

		local target_status = types.is_active_status(task.core.status) and types.STATUS.COMPLETED
			or (task.core.previous_status or status_domain.get_default())

		-- ⭐ 使用 relation 模块收集所有子任务
		local all_ids = collect_all_child_ids_from_store(opts.id)
		local update_result = batch_update_storage(all_ids, target_status)

		if update_result.success == 0 then
			return false, "Toggle failed"
		end

		if not opts.batch_mode then
			local affected_ids = collect_ancestors(all_ids)
			events.emit("state_manager", {
				changed_ids = vim.tbl_keys(affected_ids),
				files = {},
				file = nil,
				bufnr = nil,
			})
		end

		return true, target_status
	end

	-----------------------------------------------------------------
	-- 情况 2：来自 TODO 文件 → 普通任务 or 双链任务
	-----------------------------------------------------------------
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "Cannot resolve file path"
	end

	local tasks = scheduler.get_tasks_for_buf(bufnr, { force_refresh = true })

	local current_task = nil
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "Not a task line"
	end

	-----------------------------------------------------------------
	-- 普通任务（无 id）→ 改文本
	-----------------------------------------------------------------
	if not current_task.id then
		local success = toggle_normal_task(bufnr, lnum, current_task)
		if success then
			if not opts.skip_write then
				autosave.request_save(bufnr)
			end

			if not opts.batch_mode then
				events.emit("state_manager", {
					changed_ids = {},
					files = { path },
					file = path,
					bufnr = bufnr,
				})
			end

			return true, "normal_toggled"
		end
		return false, "Toggle failed"
	end

	-----------------------------------------------------------------
	-- 双链任务（有 id）→ 只更新存储，不改文本
	-----------------------------------------------------------------
	local task = core.get_task(current_task.id)
	if not task then
		return false, "Task not found"
	end

	if task.core.status == types.STATUS.ARCHIVED then
		return false, "Archived tasks cannot change status"
	end

	local target_status = types.is_active_status(task.core.status) and types.STATUS.COMPLETED
		or (task.core.previous_status or status_domain.get_default())

	-- ⭐ 使用 relation 模块收集所有子任务
	local all_ids = collect_all_child_ids_from_store(current_task.id)
	local update_result = batch_update_storage(all_ids, target_status)

	if update_result.success == 0 then
		return false, "Toggle failed"
	end

	if not opts.batch_mode then
		local affected_ids = collect_ancestors(all_ids)
		events.emit("state_manager", {
			changed_ids = vim.tbl_keys(affected_ids),
			files = { path },
			file = path,
			bufnr = bufnr,
		})
	end

	if not opts.skip_write then
		autosave.request_save(bufnr)
	end

	return true, target_status
end

---------------------------------------------------------------------
-- 批量切换任务状态（可视模式范围）
---------------------------------------------------------------------
function M.toggle_range(bufnr, start_line, end_line, opts)
	opts = opts or {}

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	local results = {
		total = 0,
		success = 0,
		failed = 0,
		affected_ids = {},
	}

	-- 先收集范围内的任务 id，再剔除「祖先也在范围内」的项：
	-- 否则父任务级联完成子任务后，子任务那一行又会被单独切换一次（结果互相抵消）。
	local picked = {}
	local picked_set = {}
	for lnum = start_line, end_line do
		results.total = results.total + 1
		local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
		local parsed = text and format.parse_task_line(text) or nil
		if parsed and parsed.id and not picked_set[parsed.id] then
			picked_set[parsed.id] = true
			table.insert(picked, { id = parsed.id, lnum = lnum })
		end
	end

	local function has_selected_ancestor(id)
		local seen = {}
		local parent = relation.get_parent_id(id)
		while parent and not seen[parent] do
			if picked_set[parent] then
				return true
			end
			seen[parent] = true
			parent = relation.get_parent_id(parent)
		end
		return false
	end

	for _, item in ipairs(picked) do
		if has_selected_ancestor(item.id) then
			results.total = results.total - 1
		else
			local ok = M.toggle_line(bufnr, item.lnum, {
				skip_write = opts.skip_write,
				batch_mode = true,
			})
			if ok then
				results.success = results.success + 1
			else
				results.failed = results.failed + 1
			end
		end
	end

	-- 范围内没有任何任务行时，保持原有"逐行尝试"的行为（可能包含代码标记行）
	if #picked == 0 then
		for lnum = start_line, end_line do
			local ok = M.toggle_line(bufnr, lnum, {
				skip_write = opts.skip_write,
				batch_mode = true,
			})
			if ok then
				results.success = results.success + 1
			else
				results.failed = results.failed + 1
			end
		end
	end

	if not opts.skip_events and results.success > 0 then
		events.emit("toggle_range", {
			changed_ids = results.affected_ids,
			file = vim.api.nvim_buf_get_name(bufnr),
			bufnr = bufnr,
			batch = true,
		})
	end

	return results
end

return M
