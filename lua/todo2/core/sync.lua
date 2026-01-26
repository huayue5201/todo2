-- lua/todo2/core/sync.lua
--- @module todo2.core.sync

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------
local stats
local function get_stats()
	if not stats then
		stats = module.get("core.stats")
	end
	return stats
end

local parser
local function get_parser()
	if not parser then
		parser = module.get("core.parser")
	end
	return parser
end

---------------------------------------------------------------------
-- 父子任务联动（向上同步父任务状态）
---------------------------------------------------------------------
function M.sync_parent_child_state(tasks, bufnr)
	local changed = false

	-- 创建任务行号映射
	local task_by_line = {}
	for _, task in ipairs(tasks) do
		task_by_line[task.line_num] = task
	end

	-- 从下往上处理（先子后父）
	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks) do
		if task.parent and #task.parent.children > 0 then
			-- 确保父任务有统计信息
			if not task.parent.stats then
				local stats_module = get_stats()
				stats_module.calculate_all_stats({ task.parent })
			end

			-- 检查父任务的所有子任务
			local all_children_done = true
			for _, child in ipairs(task.parent.children) do
				if not child.is_done then
					all_children_done = false
					break
				end
			end

			-- 根据子任务状态设置父任务
			local parent = task.parent
			if all_children_done and not parent.is_done then
				-- 所有子任务完成，父任务应设为完成
				local line = vim.api.nvim_buf_get_lines(bufnr, parent.line_num - 1, parent.line_num, false)[1]
				if line then
					local new_line = line:gsub("%[ %]", "[x]")
					vim.api.nvim_buf_set_lines(bufnr, parent.line_num - 1, parent.line_num, false, { new_line })
					parent.is_done = true
					changed = true
				end
			elseif not all_children_done and parent.is_done then
				-- 有子任务未完成，父任务应设为未完成
				local line = vim.api.nvim_buf_get_lines(bufnr, parent.line_num - 1, parent.line_num, false)[1]
				if line then
					local new_line = line:gsub("%[[xX]%]", "[ ]")
					vim.api.nvim_buf_set_lines(bufnr, parent.line_num - 1, parent.line_num, false, { new_line })
					parent.is_done = false
					changed = true
				end
			end
		end
	end

	-- 如果有改变，重新计算统计
	if changed then
		local stats_module = get_stats()
		stats_module.calculate_all_stats(tasks)

		-- 递归检查更上层的父任务
		M.sync_parent_child_state(tasks, bufnr)
	end

	return changed
end

---------------------------------------------------------------------
-- ⭐ 新 parser 架构：refresh 重写
---------------------------------------------------------------------
function M.refresh(bufnr, core_module)
	-----------------------------------------------------------------
	-- 1. 获取文件路径
	-----------------------------------------------------------------
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return {}
	end

	-----------------------------------------------------------------
	-- 2. 使用 parser.parse_file(path) 获取任务树
	-----------------------------------------------------------------
	local parser_mod = get_parser()
	local tasks, roots = parser_mod.parse_file(path)

	-----------------------------------------------------------------
	-- 3. 统计
	-----------------------------------------------------------------
	local stats_mod = get_stats()
	stats_mod.calculate_all_stats(tasks)

	-----------------------------------------------------------------
	-- 4. 父子联动（向上同步）
	-----------------------------------------------------------------
	M.sync_parent_child_state(tasks, bufnr)

	-----------------------------------------------------------------
	-- 5. 渲染（通过模块管理器获取 render 模块）
	-----------------------------------------------------------------
	local render_mod = module.get("render")
	if render_mod and render_mod.render_all then
		render_mod.render_all(bufnr)
	end

	return tasks
end

return M
