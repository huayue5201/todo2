--- File: /Users/lijia/todo2/lua/todo2/ui/render.lua ---
-- lua/todo2/ui/render.lua
--- @module todo2.ui.render
--- @brief 专业版：遵循核心权威树的渲染模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 命名空间
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function get_line(bufnr, row)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if row < 0 or row >= line_count then
		return ""
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

local function extract_task_id_from_line(line)
	return format.extract_id(line)
end

---------------------------------------------------------------------
-- 获取任务的权威状态（从store）
---------------------------------------------------------------------
local function get_task_authoritative_status(task_id)
	local link_mod = module.get("store.link")
	if not link_mod then
		return nil
	end
	local todo_link = link_mod.get_todo(task_id, { verify_line = true })
	return todo_link and todo_link.status or nil
end

---------------------------------------------------------------------
-- 渲染单个任务
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local row = math.floor(task.line_num or 1) - 1
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	if row < 0 or row >= line_count then
		return
	end

	local line = get_line(bufnr, row)
	local line_len = #line

	-- 获取任务的权威状态
	local authoritative_status = nil
	if task.id then
		authoritative_status = get_task_authoritative_status(task.id)
	end
	local is_completed = authoritative_status and types.is_completed_status(authoritative_status) or false

	-- 删除线（已完成任务）
	if is_completed then
		local end_row = row
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = end_row,
			end_col = line_len,
			hl_group = "TodoStrikethrough",
			hl_mode = "combine",
			priority = 200,
		})
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = end_row,
			end_col = line_len,
			hl_group = "TodoCompleted",
			hl_mode = "combine",
			priority = 190,
		})
	end

	-- 构建行尾虚拟文本
	local virt_text_parts = {}

	-- 子任务统计
	if task.children and #task.children > 0 and task.stats then
		local done = task.stats.done or 0
		local total = task.stats.total or #task.children
		if total > 0 then
			if #virt_text_parts > 0 then
				table.insert(virt_text_parts, { " ", "Normal" })
			end
			table.insert(virt_text_parts, {
				string.format("(%d/%d)", math.floor(done), math.floor(total)),
				"Comment",
			})
		end
	end

	-- 获取存储中的链接信息并显示状态
	local task_id = task.id or extract_task_id_from_line(line)
	if task_id then
		local link_mod = module.get("store.link")
		if link_mod then
			local link = link_mod.get_todo(task_id, { verify_line = true })
			if link then
				local status_mod = require("todo2.status")
				if status_mod then
					local components = status_mod.get_display_components(link)
					if components and components.icon and components.icon ~= "" then
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { components.icon, components.icon_highlight })
					end
					if components and components.time and components.time ~= "" then
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { components.time, components.time_highlight })
					end
				end
			end
		end
	end

	if #virt_text_parts > 0 then
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
			virt_text = virt_text_parts,
			virt_text_pos = "eol",
			hl_mode = "combine",
			right_gravity = false,
			priority = 300,
		})
	end
end

---------------------------------------------------------------------
-- 递归渲染任务树
---------------------------------------------------------------------
local function render_tree(bufnr, task)
	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------
function M.render_all(bufnr, force_parse)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local core = module.get("core")
	if not core then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	local tasks, roots
	if force_parse then
		core.clear_cache()
		tasks, roots = core.parse_file(path)
	else
		tasks, roots = core.parse_file(path)
	end

	roots = roots or {}
	if not tasks or type(tasks) ~= "table" then
		return 0
	end

	core.calculate_all_stats(tasks)

	for _, task in ipairs(roots) do
		render_tree(bufnr, task)
	end

	local total_rendered = 0
	for _, _ in pairs(tasks) do
		total_rendered = total_rendered + 1
	end

	return math.floor(total_rendered)
end

---------------------------------------------------------------------
-- 增量渲染
---------------------------------------------------------------------
function M.incremental_render(bufnr, changed_lines, force_parse)
	if changed_lines and #changed_lines > 0 then
		local core = module.get("core")
		if not core then
			return M.render_all(bufnr, force_parse)
		end

		local path = vim.api.nvim_buf_get_name(bufnr)
		local tasks, roots
		if force_parse then
			core.clear_cache()
			tasks, roots = core.parse_file(path)
		else
			tasks, roots = core.parse_file(path)
		end

		if not tasks then
			return M.render_all(bufnr, force_parse)
		end

		local affected_roots = {}
		for _, lnum in ipairs(changed_lines) do
			local task = tasks[lnum]
			if task then
				local root = task
				while root.parent do
					root = root.parent
				end
				if not vim.tbl_contains(affected_roots, root) then
					table.insert(affected_roots, root)
				end
			end
		end

		if #affected_roots == 0 then
			return M.render_all(bufnr, force_parse)
		end

		core.calculate_all_stats(tasks)

		for _, root in ipairs(affected_roots) do
			M._clear_task_and_children(bufnr, root)
			render_tree(bufnr, root)
		end

		return #affected_roots
	else
		return M.render_all(bufnr, force_parse)
	end
end

function M._clear_task_and_children(bufnr, task)
	if not task then
		return
	end

	local start_line = task.line_num - 1
	local end_line = start_line

	local function count_lines(t)
		local count = 1
		for _, child in ipairs(t.children or {}) do
			count = count + count_lines(child)
		end
		return count
	end

	end_line = start_line + count_lines(task) - 1
	vim.api.nvim_buf_clear_namespace(bufnr, ns, start_line, end_line + 1)
end

---------------------------------------------------------------------
-- 基于核心事件系统的渲染
---------------------------------------------------------------------
function M.render_with_core_events(bufnr, event_data)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local core = module.get("core")
	if not core then
		return 0
	end

	if event_data and event_data.ids and #event_data.ids > 0 then
		local affected_lines = {}
		local path = vim.api.nvim_buf_get_name(bufnr)
		local tasks, _ = core.parse_file(path)

		if tasks then
			for _, id in ipairs(event_data.ids) do
				for _, task in pairs(tasks) do
					if task.id == id then
						table.insert(affected_lines, task.line_num)
						break
					end
				end
			end

			if #affected_lines > 0 then
				return M.incremental_render(bufnr, affected_lines, true)
			end
		end
	end

	return M.render_all(bufnr, true)
end

---------------------------------------------------------------------
-- 清理缓存
---------------------------------------------------------------------
function M.clear_cache()
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end
end

---------------------------------------------------------------------
-- 统一渲染接口
---------------------------------------------------------------------
function M.render_with_core(bufnr, options)
	options = vim.tbl_extend("force", {
		force_refresh = false,
		incremental = false,
		changed_lines = {},
		event_source = nil,
	}, options or {})

	if options.incremental and #options.changed_lines > 0 then
		return M.incremental_render(bufnr, options.changed_lines, options.force_refresh)
	elseif options.event_source then
		return M.render_with_core_events(bufnr, options.event_source)
	else
		return M.render_all(bufnr, options.force_refresh)
	end
end

return M
