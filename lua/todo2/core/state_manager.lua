-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 负责活跃状态 ↔ 完成状态的双向切换

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local link_mod = require("todo2.store.link")
local events = require("todo2.core.events")
local stats = require("todo2.core.stats")
local parser = require("todo2.core.parser")
local autosave = require("todo2.core.autosave")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
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
-- 从存储同步任务数据
---------------------------------------------------------------------
local function sync_task_from_store(task)
	if not task or not task.id then
		return task
	end

	local stored = link_mod.get_todo(task.id, { verify_line = false })
	if stored then
		task.status = stored.status
		task.previous_status = stored.previous_status
		task.archived_at = stored.archived_at
		task.completed_at = stored.completed_at
		task.pending_restore_status = stored.pending_restore_status
	end
	return task
end

---------------------------------------------------------------------
-- ⭐ 自底向上切换任务状态（父任务 → 子任务）
---------------------------------------------------------------------
local function toggle_task_with_children(task, bufnr, target_status)
	if not task or not task.id then
		return false
	end

	-- 先从存储同步最新数据
	task = sync_task_from_store(task)

	-- 确定目标状态
	local target_status = target_status
		or (
			types.is_active_status(task.status) and types.STATUS.COMPLETED
			or task.previous_status
			or types.STATUS.NORMAL
		)

	local target_checkbox = types.status_to_checkbox(target_status)
	local current_checkbox = types.status_to_checkbox(task.status)

	-- 如果状态已经符合目标，跳过
	if task.status == target_status then
		return true
	end

	-- 先切换子任务（自底向上）
	if task.children and #task.children > 0 then
		for _, child in ipairs(task.children) do
			local child_target
			if target_status == types.STATUS.COMPLETED then
				-- 父任务完成，子任务也应完成
				child_target = types.STATUS.COMPLETED
			else
				-- 父任务恢复，子任务恢复到各自之前的状态
				child_target = child.previous_status or types.STATUS.NORMAL
			end
			toggle_task_with_children(child, bufnr, child_target)
		end
	end

	-- 最后切换父任务
	local success = replace_status(bufnr, task.line_num, current_checkbox, target_checkbox)

	if success then
		-- 更新任务状态
		local old_status = task.status
		task.status = target_status

		-- 更新存储
		if task.id then
			if target_status == types.STATUS.COMPLETED then
				link_mod.mark_completed(task.id)
			else
				link_mod.update_active_status(task.id, target_status)
			end

			-- 重新同步以确保 previous_status 正确
			local updated = link_mod.get_todo(task.id, { verify_line = false })
			if updated then
				task.previous_status = updated.previous_status
			end
		end

		-- 触发事件
		if events then
			events.on_state_changed({
				source = target_status == types.STATUS.COMPLETED and "toggle_complete" or "toggle_reopen",
				ids = { task.id },
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
				timestamp = os.time() * 1000,
			})
		end
	end

	return success
end

---------------------------------------------------------------------
-- 移除原来的 ensure_parent_child_consistency 函数
-- 不再需要自动完成父任务的逻辑
---------------------------------------------------------------------

---------------------------------------------------------------------
-- 核心API：切换任务状态（活跃 ↔ 完成）
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	if not parser then
		return false, "解析器模块未找到"
	end

	local tasks, roots = parser.parse_file(path)
	if not tasks then
		return false, "解析任务失败"
	end

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

	-- 切换前从存储同步数据
	current_task = sync_task_from_store(current_task)

	-- 使用自底向上的切换函数
	local success = toggle_task_with_children(current_task, bufnr)
	if not success then
		return false, "切换失败"
	end

	-- 重新计算统计
	if stats and stats.calculate_all_stats then
		stats.calculate_all_stats(tasks)
	end

	-- 自动保存
	if not opts.skip_write then
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	-- 返回新状态是否已完成
	return true, types.is_completed_status(current_task.status)
end

return M
