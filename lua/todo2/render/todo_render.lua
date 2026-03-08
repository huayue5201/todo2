-- lua/todo2/render/todo_render.lua

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core_stats = require("todo2.core.stats")
local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")

local NS = vim.api.nvim_create_namespace("todo2_render")
local DEBUG = false

local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

local function get_cached_task_tree(path, force_refresh)
	return scheduler.get_parse_tree(path, force_refresh)
end

local function get_authoritative_status(task_id)
	if not link or not task_id then
		return nil
	end
	local todo_link = link.get_todo(task_id, { verify_line = true })
	return todo_link and todo_link.status or nil
end

local function get_authoritative_link(task_id)
	if not link or not task_id then
		return nil
	end
	return link.get_todo(task_id, { verify_line = true })
end

local function get_line_safe(bufnr, row)
	if not is_valid_line(bufnr, row) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function apply_completed_visuals(bufnr, row, line_len)
	if not is_valid_line(bufnr, row) then
		return
	end

	pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
		end_row = row,
		end_col = line_len,
		hl_group = "TodoStrikethrough",
		hl_mode = "combine",
		priority = 200,
	})

	pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
		end_row = row,
		end_col = line_len,
		hl_group = "TodoCompleted",
		hl_mode = "combine",
		priority = 190,
	})
end

local function build_status_display(task_id, current_parts)
	if not task_id or not link or not status then
		return current_parts
	end

	local link_obj = get_authoritative_link(task_id)
	if not link_obj then
		return current_parts
	end

	local components = status.get_display_components(link_obj)
	if not components then
		return current_parts
	end

	if components.icon and components.icon ~= "" then
		table.insert(current_parts, { "  ", "Normal" })
		table.insert(current_parts, { components.icon, components.icon_highlight })
	end

	if components.time and components.time ~= "" then
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, { components.time, components.time_highlight })
	end

	return current_parts
end

local function build_progress_display(task, current_parts)
	if not task or not task.children or #task.children == 0 then
		return current_parts
	end

	local progress = core_stats.calc_group_progress(task)

	if progress.total <= 1 then
		return current_parts
	end

	local progress_virt = config.format_progress_bar(progress)
	vim.list_extend(current_parts, progress_virt)

	return current_parts
end

---------------------------------------------------------------------
-- ⭐ 支持增量渲染的单任务渲染
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not task then
		return
	end

	local row = (task.line_num or 1) - 1
	if row < 0 then
		return
	end

	-- ⭐ 单行增量渲染
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	if not format.is_task_line(line) then
		return
	end

	local is_completed = false
	if task.id then
		local st = get_authoritative_status(task.id)
		is_completed = st and types.is_completed_status(st)
	end

	if is_completed then
		apply_completed_visuals(bufnr, row, #line)
	end

	local virt = {}
	virt = build_progress_display(task, virt)
	virt = build_status_display(task.id, virt)

	if #virt > 0 then
		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, -1, {
			virt_text = virt,
			virt_text_pos = "inline",
			hl_mode = "combine",
			right_gravity = true,
			priority = 100,
		})
	end
end

local function render_tree(bufnr, task)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

function M.render(bufnr, opts)
	opts = opts or {}

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	local tasks, roots = get_cached_task_tree(path, opts.force_refresh)

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	if not tasks or #tasks == 0 then
		return 0
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	vim.b[bufnr].todo2_last_line_count = line_count

	core_stats.calculate_all_stats(tasks)

	for _, root in ipairs(roots) do
		pcall(render_tree, bufnr, root)
	end

	if DEBUG then
		vim.notify(string.format("已渲染 %d 个任务", #tasks), vim.log.levels.DEBUG)
	end

	return #tasks
end

function M.clear_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

function M.clear_all()
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end
end

function M.clear_parser_cache(path)
	scheduler.invalidate_cache(path)
end

M.clear = M.clear_all

return M
