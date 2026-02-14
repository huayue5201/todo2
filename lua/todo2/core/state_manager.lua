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
-- ⭐ 从存储同步任务数据
---------------------------------------------------------------------
local function sync_task_from_store(task)
	if not task or not task.id then
		return task
	end

	local stored = link_mod.get_todo(task.id, { verify_line = false })
	if stored then
		-- 同步存储中的状态数据
		task.status = stored.status
		task.previous_status = stored.previous_status
		task.archived_at = stored.archived_at
		task.completed_at = stored.completed_at
		task.pending_restore_status = stored.pending_restore_status
	end
	return task
end

---------------------------------------------------------------------
-- ⭐ 切换任务状态（活跃 ↔ 完成）
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)

	if not link_mod then
		return false
	end

	-- ⭐ 先从存储同步最新数据
	task = sync_task_from_store(task)

	local current_status = task.status or types.STATUS.NORMAL
	local new_status, checkbox

	-- 归档状态不归这里管
	if current_status == types.STATUS.ARCHIVED then
		vim.notify("归档任务请使用撤销归档功能", vim.log.levels.WARN)
		return false
	end

	-- 双向切换：活跃 ↔ 完成
	if types.is_active_status(current_status) then
		-- 活跃 → 完成
		new_status = types.STATUS.COMPLETED
		checkbox = "[x]"
	elseif current_status == types.STATUS.COMPLETED then
		-- ⭐ 完成 → 活跃（恢复到之前的状态）
		new_status = task.previous_status or types.STATUS.NORMAL
		checkbox = types.status_to_checkbox(new_status)
	else
		return false
	end

	-- 替换文件中的复选框
	local old_checkbox = types.status_to_checkbox(current_status)
	local success = replace_status(bufnr, task.line_num, old_checkbox, checkbox)

	if success then
		-- 更新解析器中的任务状态
		task.status = new_status

		-- 更新存储
		if task.id then
			if new_status == types.STATUS.COMPLETED then
				-- 完成任务（自动记录 previous_status）
				link_mod.mark_completed(task.id)
			else
				-- 从完成恢复到活跃（传入正确的状态）
				link_mod.update_active_status(task.id, new_status)
			end

			-- ⭐ 关键修复：从存储重新获取，确保 previous_status 正确
			local updated = link_mod.get_todo(task.id, { verify_line = false })
			if updated then
				task.previous_status = updated.previous_status
			end

			-- 触发事件
			if events then
				events.on_state_changed({
					source = new_status == types.STATUS.COMPLETED and "toggle_complete" or "toggle_reopen",
					ids = { task.id },
					file = path,
					bufnr = bufnr,
					timestamp = os.time() * 1000,
				})
			end
		end

		-- 递归处理子任务
		local function toggle_children(child_task)
			for _, child in ipairs(child_task.children or {}) do
				if new_status == types.STATUS.COMPLETED then
					-- 子任务也应完成
					if not types.is_completed_status(child.status) then
						local child_checkbox = types.status_to_checkbox(child.status)
						replace_status(bufnr, child.line_num, child_checkbox, "[x]")
						child.status = types.STATUS.COMPLETED
						if child.id then
							link_mod.mark_completed(child.id)

							-- ⭐ 子任务也从存储同步
							local child_updated = link_mod.get_todo(child.id, { verify_line = false })
							if child_updated then
								child.previous_status = child_updated.previous_status
							end
						end
					end
				else
					-- 子任务应恢复到之前的状态
					if types.is_completed_status(child.status) then
						local target_status = child.previous_status or types.STATUS.NORMAL
						local target_checkbox = types.status_to_checkbox(target_status)

						replace_status(bufnr, child.line_num, "[x]", target_checkbox)
						child.status = target_status
						if child.id then
							link_mod.update_active_status(child.id, target_status)
						end
					end
				end
				toggle_children(child)
			end
		end

		if task.children and #task.children > 0 then
			toggle_children(task)
		end
	end

	return success
end

---------------------------------------------------------------------
-- 确保父子状态一致性
---------------------------------------------------------------------
local function ensure_parent_child_consistency(tasks, bufnr)
	local changed = false

	if not link_mod then
		return false
	end

	-- 从下往上处理
	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks) do
		local parent = task.parent
		if parent and #parent.children > 0 then
			local all_children_done = true
			for _, child in ipairs(parent.children) do
				if not types.is_completed_status(child.status) then
					all_children_done = false
					break
				end
			end

			if all_children_done and not types.is_completed_status(parent.status) then
				-- 所有子任务完成，父任务也应完成
				local parent_checkbox = types.status_to_checkbox(parent.status)
				replace_status(bufnr, parent.line_num, parent_checkbox, "[x]")
				parent.status = types.STATUS.COMPLETED
				if parent.id then
					link_mod.mark_completed(parent.id)
				end
				changed = true
			elseif not all_children_done and types.is_completed_status(parent.status) then
				-- 有子任务未完成，父任务不应完成
				local target_status = parent.previous_status or types.STATUS.NORMAL
				local target_checkbox = types.status_to_checkbox(target_status)

				replace_status(bufnr, parent.line_num, "[x]", target_checkbox)
				parent.status = target_status
				if parent.id then
					link_mod.update_active_status(parent.id, target_status)
				end
				changed = true
			end
		end
	end

	if changed then
		if stats and stats.calculate_all_stats then
			stats.calculate_all_stats(tasks)
		end
		ensure_parent_child_consistency(tasks, bufnr)
	end

	return changed
end

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

	-- ⭐ 切换前从存储同步数据
	current_task = sync_task_from_store(current_task)

	local success = toggle_task_and_children(current_task, bufnr)
	if not success then
		return false, "切换失败"
	end

	-- 重新计算统计
	if stats and stats.calculate_all_stats then
		stats.calculate_all_stats(tasks)
	end

	-- 确保父子一致性
	ensure_parent_child_consistency(tasks, bufnr)

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
