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
-- ⭐ 修复点1：简化切换任务状态逻辑，使用正确字段
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local link_mod = module.get("store.link")
	local path = vim.api.nvim_buf_get_name(bufnr)

	if not link_mod then
		return false
	end

	local success
	local old_completed = task.completed -- 使用 completed 字段

	if task.completed then
		-- 从完成状态变为未完成
		success = replace_status(bufnr, task.line_num, "[x]", "[ ]")
		if success then
			task.completed = false
			-- 删除：task.is_done = false
			task.status = types.STATUS.NORMAL

			if task.id then
				local result = link_mod.reopen_link(task.id, "todo")
				if not result then
					vim.notify("重新打开链接失败: " .. task.id, vim.log.levels.WARN)
				end

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
			task.completed = true
			-- 删除：task.is_done = true
			task.status = types.STATUS.COMPLETED

			if task.id then
				local todo_link = link_mod.get_todo(task.id, { verify_line = false })
				if todo_link then
					if not todo_link.completed then
						local result = link_mod.mark_completed(task.id, "todo")
						if not result then
							vim.notify("标记完成失败: " .. task.id, vim.log.levels.WARN)
						end
					end
				else
					local result = link_mod.mark_completed(task.id, "todo")
					if not result then
						vim.notify("创建完成链接失败: " .. task.id, vim.log.levels.WARN)
					end
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

	-- 向下传播时使用 completed 字段
	local function toggle_children(child_task)
		for _, child in ipairs(child_task.children or {}) do
			if task.completed then
				-- 子任务也应该完成
				if not child.completed then
					replace_status(bufnr, child.line_num, "[ ]", "[x]")
					child.completed = true
					-- 删除：child.is_done = true
					child.status = types.STATUS.COMPLETED

					if child.id then
						local result = link_mod.mark_completed(child.id, "todo")
						if not result then
							vim.notify("子任务完成失败: " .. child.id, vim.log.levels.WARN)
						end
					end
				end
			else
				-- 子任务也应该重新打开
				if child.completed then
					replace_status(bufnr, child.line_num, "[x]", "[ ]")
					child.completed = false
					-- 删除：child.is_done = false
					child.status = types.STATUS.NORMAL

					if child.id then
						local result = link_mod.reopen_link(child.id, "todo")
						if not result then
							vim.notify("子任务重新打开失败: " .. child.id, vim.log.levels.WARN)
						end
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
-- ⭐ 修复点3：确保父子状态一致性，使用正确字段
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
				if not child.completed then -- 使用 completed 字段
					all_children_done = false
					break
				end
			end

			if all_children_done and not parent.completed then
				-- 所有子任务完成，父任务也应该完成
				replace_status(bufnr, parent.line_num, "[ ]", "[x]")
				parent.completed = true
				-- 删除：parent.is_done = true
				parent.status = types.STATUS.COMPLETED

				if parent.id then
					local result = link_mod.mark_completed(parent.id, "todo")
					if result then
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
					else
						vim.notify("父任务自动完成失败: " .. parent.id, vim.log.levels.WARN)
					end
				end
				changed = true
			elseif not all_children_done and parent.completed then
				-- 有子任务未完成，父任务不应该完成
				replace_status(bufnr, parent.line_num, "[x]", "[ ]")
				parent.completed = false
				-- 删除：parent.is_done = false
				parent.status = types.STATUS.NORMAL

				if parent.id then
					local result = link_mod.reopen_link(parent.id, "todo")
					if result then
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
					else
						vim.notify("父任务自动重新打开失败: " .. parent.id, vim.log.levels.WARN)
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

	return true, current_task.completed
end

-- 导出内部函数用于测试
M._replace_status = replace_status
M._ensure_parent_child_consistency = ensure_parent_child_consistency

return M
