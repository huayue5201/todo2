-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 合并 toggle + sync 的状态管理器

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	local start_col, end_col = line:find(from)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

---------------------------------------------------------------------
-- 切换任务状态（含向下传播）
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local success

	if task.is_done then
		success = replace_status(bufnr, task.line_num, "%[[xX]%]", "[ ]")
		task.is_done = false
		task.status = "[ ]"
	else
		success = replace_status(bufnr, task.line_num, "%[ %]", "[x]")
		task.is_done = true
		task.status = "[x]"
	end

	if not success then
		return false
	end

	-- 向下传播：递归切换所有子任务状态
	local function toggle_children(child_task)
		for _, child in ipairs(child_task.children) do
			if task.is_done then
				replace_status(bufnr, child.line_num, "%[ %]", "[x]")
				child.is_done = true
				child.status = "[x]"
			else
				replace_status(bufnr, child.line_num, "%[[xX]%]", "[ ]")
				child.is_done = false
				child.status = "[ ]"
			end
			toggle_children(child)
		end
	end

	toggle_children(task)
	return true
end

---------------------------------------------------------------------
-- 确保父子状态一致性（向上同步）
---------------------------------------------------------------------
local function ensure_parent_child_consistency(tasks, bufnr)
	local changed = false
	local task_by_line = {}

	for _, task in ipairs(tasks) do
		task_by_line[task.line_num] = task
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
				replace_status(bufnr, parent.line_num, "%[ %]", "[x]")
				parent.is_done = true
				parent.status = "[x]"
				changed = true
			elseif not all_children_done and parent.is_done then
				replace_status(bufnr, parent.line_num, "%[[xX]%]", "[ ]")
				parent.is_done = false
				parent.status = "[ ]"
				changed = true
			end
		end
	end

	if changed then
		local stats_mod = module.get("core.stats")
		stats_mod.calculate_all_stats(tasks)
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

	local parser_mod = module.get("core.parser")
	local tasks, roots = parser_mod.parse_file(path)

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

	local stats_mod = module.get("core.stats")
	stats_mod.calculate_all_stats(tasks)

	ensure_parent_child_consistency(tasks, bufnr)

	if not opts.skip_write then
		local autosave = module.get("core.autosave")
		autosave.request_save(bufnr)
	end

	return true, current_task.is_done
end

---------------------------------------------------------------------
-- 核心API：刷新任务树
---------------------------------------------------------------------
function M.refresh(bufnr, main_module)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return {}
	end

	local parser_mod = module.get("core.parser")
	local tasks, roots = parser_mod.parse_file(path)

	local stats_mod = module.get("core.stats")
	stats_mod.calculate_all_stats(tasks)

	ensure_parent_child_consistency(tasks, bufnr)

	local render_mod = module.get("render")
	if render_mod and render_mod.render_all then
		render_mod.render_all(bufnr)
	end

	return tasks
end

-- 导出内部函数用于测试
M._replace_status = replace_status
M._ensure_parent_child_consistency = ensure_parent_child_consistency

return M
