--- File: /Users/lijia/todo2/lua/todo2/core/state_manager.lua ---
-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 复选框状态切换管理器（修复状态同步问题）

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
-- ⭐ 修复点1：简化切换任务状态逻辑
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local link_mod = module.get("store.link")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if not link_mod then
		return false
	end

	local success
	local old_is_done = task.is_done

	if task.is_done then
		-- 从完成状态变为未完成
		success = replace_status(bufnr, task.line_num, "[x]", "[ ]")
		if success then
			task.is_done = false
			task.status = "[ ]"

			if task.id then
				-- ⭐ 关键修复：确保存储状态同步
				link_mod.reopen_link(task.id, "todo")

				-- 立即触发事件
				local events = module.get("core.events")
				if events then
					events.on_state_changed({
						source = "toggle_reopen",
						ids = { task.id },
						file = path,
						bufnr = bufnr,
						timestamp = os.time() * 1000,
					})
				end
			end
		end
	else
		-- 从未完成状态变为完成
		success = replace_status(bufnr, task.line_num, "[ ]", "[x]")
		if success then
			task.is_done = true
			task.status = "[x]"

			if task.id then
				-- ⭐ 关键修复：确保存储状态同步
				local todo_link = link_mod.get_todo(task.id, { verify_line = false })
				if todo_link then
					-- 如果存储中已经标记为完成，则不需要再次标记
					if not todo_link.completed then
						link_mod.mark_completed(task.id, "todo")
					end
				else
					-- 如果没有存储记录，创建一个
					link_mod.mark_completed(task.id, "todo")
				end

				local events = module.get("core.events")
				if events then
					events.on_state_changed({
						source = "toggle_complete",
						ids = { task.id },
						file = path,
						bufnr = bufnr,
						timestamp = os.time() * 1000,
					})
				end
			end
		end
	end

	if not success then
		return false
	end

	-- ⭐ 修复点2：向下传播时确保存储状态同步
	local function toggle_children(child_task)
		for _, child in ipairs(child_task.children or {}) do
			if task.is_done then
				-- 子任务也应该完成
				if not child.is_done then
					replace_status(bufnr, child.line_num, "[ ]", "[x]")
					child.is_done = true
					child.status = "[x]"

					if child.id then
						link_mod.mark_completed(child.id, "todo")
					end
				end
			else
				-- 子任务也应该重新打开
				if child.is_done then
					replace_status(bufnr, child.line_num, "[x]", "[ ]")
					child.is_done = false
					child.status = "[ ]"

					if child.id then
						link_mod.reopen_link(child.id, "todo")
					end
				end
			end
			toggle_children(child)
		end
	end

	if task.children and #task.children > 0 then
		toggle_children(task)
	end

	return true
end

---------------------------------------------------------------------
-- ⭐ 修复点3：确保父子状态一致性
---------------------------------------------------------------------
local function ensure_parent_child_consistency(tasks, bufnr)
	local changed = false
	local link_mod = module.get("store.link")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if not link_mod then
		return false
	end

	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks) do
		local parent = task.parent
		if parent and #parent.children > 0 then
			local all_children_done = true
			for _, child in ipairs(parent.children) do
				if not child.is_done then
					all_children_done = false
					break
				end
			end

			if all_children_done and not parent.is_done then
				-- 所有子任务完成，父任务也应该完成
				replace_status(bufnr, parent.line_num, "[ ]", "[x]")
				parent.is_done = true
				parent.status = "[x]"

				if parent.id then
					link_mod.mark_completed(parent.id, "todo")

					-- 触发事件
					local events = module.get("core.events")
					if events then
						events.on_state_changed({
							source = "parent_auto_complete",
							ids = { parent.id },
							file = path,
							bufnr = bufnr,
							timestamp = os.time() * 1000,
						})
					end
				end
				changed = true
			elseif not all_children_done and parent.is_done then
				-- 有子任务未完成，父任务不应该完成
				replace_status(bufnr, parent.line_num, "[x]", "[ ]")
				parent.is_done = false
				parent.status = "[ ]"

				if parent.id then
					link_mod.reopen_link(parent.id, "todo")

					-- 触发事件
					local events = module.get("core.events")
					if events then
						events.on_state_changed({
							source = "parent_auto_reopen",
							ids = { parent.id },
							file = path,
							bufnr = bufnr,
							timestamp = os.time() * 1000,
						})
					end
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
		-- 递归检查，因为父任务状态变化可能影响祖父任务
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

	local stats = module.get("core.stats")
	if stats and stats.calculate_all_stats then
		stats.calculate_all_stats(tasks)
	end

	-- 确保父子一致性
	ensure_parent_child_consistency(tasks, bufnr)

	-- 保存文件
	if not opts.skip_write then
		local autosave = module.get("core.autosave")
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	return true, current_task.is_done
end

-- 导出内部函数用于测试
M._replace_status = replace_status
M._ensure_parent_child_consistency = ensure_parent_child_consistency

return M
