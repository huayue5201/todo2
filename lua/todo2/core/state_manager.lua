--- File: /Users/lijia/todo2/lua/todo2/core/state_manager.lua ---
-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 复选框状态切换管理器（移除 completed 字段）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")

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
-- 切换任务状态（基于 status 字段）
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local link_mod = module.get("store.link")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if not link_mod then
		return false
	end

	-- 当前状态
	local current_status = task.status or types.STATUS.NORMAL
	local new_status, checkbox

	if types.is_completed_status(current_status) then
		-- 完成状态 → 重新打开为 normal
		new_status = types.STATUS.NORMAL
		checkbox = "[ ]"
	else
		-- 活跃状态 → 完成
		new_status = types.STATUS.COMPLETED
		checkbox = "[x]"
	end

	-- 替换文件中的复选框
	local success =
		replace_status(bufnr, task.line_num, types.is_completed_status(current_status) and "[x]" or "[ ]", checkbox)

	if success then
		-- 更新解析器中的任务状态
		task.status = new_status

		-- 更新存储
		if task.id then
			if new_status == types.STATUS.COMPLETED then
				link_mod.mark_completed(task.id)
			else
				link_mod.reopen_link(task.id)
			end

			-- 触发事件
			local events = module.get("core.events")
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
						replace_status(bufnr, child.line_num, "[ ]", "[x]")
						child.status = types.STATUS.COMPLETED
						if child.id then
							link_mod.mark_completed(child.id)
						end
					end
				else
					-- 子任务应重新打开
					if types.is_completed_status(child.status) then
						replace_status(bufnr, child.line_num, "[x]", "[ ]")
						child.status = types.STATUS.NORMAL
						if child.id then
							link_mod.reopen_link(child.id)
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
	local link_mod = module.get("store.link")
	local path = vim.api.nvim_buf_get_name(bufnr)

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
				replace_status(bufnr, parent.line_num, "[ ]", "[x]")
				parent.status = types.STATUS.COMPLETED
				if parent.id then
					link_mod.mark_completed(parent.id)
				end
				changed = true
			elseif not all_children_done and types.is_completed_status(parent.status) then
				-- 有子任务未完成，父任务不应完成
				replace_status(bufnr, parent.line_num, "[x]", "[ ]")
				parent.status = types.STATUS.NORMAL
				if parent.id then
					link_mod.reopen_link(parent.id)
				end
				changed = true
			end
		end
	end

	if changed then
		local stats = module.get("core.stats")
		if stats and stats.calculate_all_stats then
			stats.calculate_all_stats(tasks)
		end
		-- 递归检查，因为改变父任务可能影响更高层级
		ensure_parent_child_consistency(tasks, bufnr)
	end

	return changed
end

---------------------------------------------------------------------
-- 核心API：切换任务状态
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	local parser = module.get("core.parser")
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

	local success = toggle_task_and_children(current_task, bufnr)
	if not success then
		return false, "切换失败"
	end

	-- 重新计算统计
	local stats = module.get("core.stats")
	if stats and stats.calculate_all_stats then
		stats.calculate_all_stats(tasks)
	end

	-- 确保父子一致性
	ensure_parent_child_consistency(tasks, bufnr)

	-- 自动保存
	if not opts.skip_write then
		local autosave = module.get("core.autosave")
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	-- 返回新状态是否已完成
	return true, types.is_completed_status(current_task.status)
end

return M
