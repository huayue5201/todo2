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
-- 父子任务联动（保持原逻辑）
---------------------------------------------------------------------
function M.sync_parent_child_state(tasks, bufnr)
	local changed = false

	for _, task in ipairs(tasks) do
		if #task.children > 0 then
			-- 确保有统计信息
			if not task.stats then
				local stats_module = get_stats()
				stats_module.calculate_all_stats({ task })
			end

			local stats = task.stats
			local should_done = stats.done == stats.total
			local current_done = task.is_done

			if should_done ~= current_done then
				local line = vim.api.nvim_buf_get_lines(bufnr, task.line_num - 1, task.line_num, false)[1]
				if line then
					if should_done then
						local new_line = line:gsub("%[ %]", "[x]")
						vim.api.nvim_buf_set_lines(bufnr, task.line_num - 1, task.line_num, false, { new_line })
						task.is_done = true
					else
						local new_line = line:gsub("%[[xX]%]", "[ ]")
						vim.api.nvim_buf_set_lines(bufnr, task.line_num - 1, task.line_num, false, { new_line })
						task.is_done = false
					end
					changed = true
				end
			end
		end
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
	-- 4. 父子联动（不写盘）
	-----------------------------------------------------------------
	if M.sync_parent_child_state(tasks, bufnr) then
		-- 如果父任务状态改变 → 重新解析一次（保持一致性）
		tasks, roots = parser_mod.parse_file(path)
		stats_mod.calculate_all_stats(tasks)
	end

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
