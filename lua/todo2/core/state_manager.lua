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
local parser = require("todo2.core.parser")
local autosave = require("todo2.core.autosave")
local renderer = require("todo2.link.renderer")
local render = require("todo2.ui.render")

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
-- ⭐ 修复：找到更新后的任务对象
---------------------------------------------------------------------
local function find_updated_task(tasks, task_id)
	for _, task in ipairs(tasks) do
		if task.id == task_id then
			return task
		end
		if task.children and #task.children > 0 then
			local found = find_updated_task(task.children, task_id)
			if found then
				return found
			end
		end
	end
	return nil
end

---------------------------------------------------------------------
-- ⭐ 新增：普通任务的简化切换（无ID任务）
---------------------------------------------------------------------
local function simple_toggle_task(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	-- 只在 [ ] 和 [x] 之间切换
	local new_line
	if line:match("%[ %]") then
		-- [ ] 变为 [x]
		new_line = line:gsub("%[ %]", "[x]", 1)
	elseif line:match("%[x%]") then
		-- [x] 变为 [ ]
		new_line = line:gsub("%[x%]", "[ ]", 1)
	else
		return false -- 不是可切换的任务行
	end

	-- ⭐ 手动触发渲染
	-- DEBUG:ref:3fd788
	-- render.render(bufnr, { force_refresh = true })
	-- 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
	return true
end

---------------------------------------------------------------------
-- ⭐ 修复：自底向上切换任务状态（支持混合类型）
---------------------------------------------------------------------
local function toggle_task_with_children(task, bufnr, target_status)
	if not task then
		return false
	end

	-- ⭐ 如果是普通任务（无ID），使用简化切换
	if not task.id then
		local line = vim.api.nvim_buf_get_lines(bufnr, task.line_num - 1, task.line_num, false)[1]
		if not line then
			return false
		end

		local new_line
		if line:match("%[ %]") then
			new_line = line:gsub("%[ %]", "[x]", 1)
		elseif line:match("%[x%]") then
			new_line = line:gsub("%[x%]", "[ ]", 1)
		else
			return false
		end

		vim.api.nvim_buf_set_lines(bufnr, task.line_num - 1, task.line_num, false, { new_line })
		return true
	end

	task = sync_task_from_store(task)

	-- 确定目标状态
	target_status = target_status
	if not target_status then
		if types.is_active_status(task.status) then
			target_status = types.STATUS.COMPLETED
		else
			-- ⭐ 从完成/归档状态回切：使用 previous_status
			target_status = task.previous_status or types.STATUS.NORMAL
		end
	end

	local target_checkbox = types.status_to_checkbox(target_status)
	local current_checkbox = types.status_to_checkbox(task.status)

	if task.status == target_status then
		return true
	end

	-- ⭐ 修复：递归切换子任务（支持混合类型）
	if task.children and #task.children > 0 then
		for _, child in ipairs(task.children) do
			local child_target
			if target_status == types.STATUS.COMPLETED then
				child_target = types.STATUS.COMPLETED
			else
				-- 如果是双链子任务，使用 previous_status
				if child.id then
					child_target = child.previous_status or types.STATUS.NORMAL
				else
					-- 普通子任务，根据父任务目标状态决定
					child_target = target_status == types.STATUS.COMPLETED and types.STATUS.COMPLETED
						or types.STATUS.NORMAL
				end
			end
			toggle_task_with_children(child, bufnr, child_target)
		end
	end

	-- 切换父任务
	local success = replace_status(bufnr, task.line_num, current_checkbox, target_checkbox)

	if success then
		task.status = target_status

		if task.id then
			if target_status == types.STATUS.COMPLETED then
				link_mod.mark_completed(task.id) -- ✅ 记录 previous_status
			else
				-- ⭐ 从完成状态回切：使用 reopen_link
				if types.is_completed_status(task.status) and target_status ~= types.STATUS.COMPLETED then
					link_mod.reopen_link(task.id) -- ✅ 恢复 previous_status
				else
					link_mod.update_active_status(task.id, target_status)
				end
			end
		end

		-- TODO:ref:bf7944
		events.on_state_changed({
			source = target_status == types.STATUS.COMPLETED and "toggle_complete" or "toggle_reopen",
			ids = { task.id },
			file = vim.api.nvim_buf_get_name(bufnr),
			bufnr = bufnr,
			timestamp = os.time() * 1000,
		})
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 修复：修改原有的 toggle_line 函数，支持普通任务刷新
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
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

	-- ⭐ 新增：判断是否为普通任务（无ID）
	if not current_task.id then
		-- 普通任务：使用简化切换
		local success = simple_toggle_task(bufnr, lnum)
		if success then
			-- 只触发自动保存，不触发事件，不更新存储
			if not opts.skip_write then
				autosave.request_save(bufnr)
			end
			return true, "normal_toggled"
		else
			return false, "切换失败"
		end
	end

	-- ⭐ 以下是原有的双链任务代码，一字不改
	current_task = sync_task_from_store(current_task)

	local success = toggle_task_with_children(current_task, bufnr)
	if not success then
		return false, "切换失败"
	end

	-- ⭐ 强制重新解析文件，确保任务树更新
	local new_tasks, new_roots = parser.parse_file(path, true)

	-- ⭐ 修复：找到更新后的任务对象
	local updated_task = nil
	if current_task and current_task.id then
		updated_task = find_updated_task(new_tasks, current_task.id)
	end

	-- ⭐ 修复：使用更新后的任务对象渲染
	local function render_task_and_parents(task)
		if task and task.line_num then
			renderer.render_line(bufnr, task.line_num - 1)
			if task.parent then
				render_task_and_parents(task.parent)
			end
		end
	end

	-- 如果有更新后的任务，使用它；否则使用当前任务
	local task_to_render = updated_task or current_task
	render_task_and_parents(task_to_render)

	-- 自动保存
	if not opts.skip_write then
		autosave.request_save(bufnr)
	end

	return true, types.is_completed_status(task_to_render.status)
end

return M
