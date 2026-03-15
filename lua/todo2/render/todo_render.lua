-- lua/todo2/render/todo_render.lua
-- 最终版：复选框自动对齐存储 + 行号以存储为权威 + 自动保存 + 完整增量渲染

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core_stats = require("todo2.core.stats")
local core = require("todo2.store.link.core")
local scheduler = require("todo2.render.scheduler")
local progress_render = require("todo2.render.progress")
local autosave = require("todo2.core.autosave")

local NS = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

local function get_line_safe(bufnr, row)
	if not is_valid_line(bufnr, row) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function get_authoritative_status(task_id)
	if not task_id then
		return nil
	end
	local task = core.get_task(task_id)
	return task and task.core.status or nil
end

---------------------------------------------------------------------
-- 行号以存储为权威
---------------------------------------------------------------------
local function get_authoritative_row(task)
	if not task or not task.id then
		return (task.line_num or 1) - 1
	end

	local t = core.get_task(task.id)
	if t and t.locations.todo and t.locations.todo.line then
		return t.locations.todo.line - 1
	end

	return (task.line_num or 1) - 1
end

---------------------------------------------------------------------
-- 删除线
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 复选框自动对齐存储状态 + 自动保存
---------------------------------------------------------------------
local function sync_checkbox_with_storage(bufnr, row, task)
	if not task or not task.id then
		return
	end

	local line = get_line_safe(bufnr, row)
	if not line or line == "" then
		return
	end

	local stored_status = get_authoritative_status(task.id)
	if not stored_status then
		return
	end

	local expected_checkbox = types.status_to_checkbox(stored_status)
	if not expected_checkbox then
		return
	end

	local start_col, end_col = format.get_checkbox_position(line)
	if not start_col or not end_col then
		return
	end

	local current_checkbox = line:sub(start_col, end_col)
	if current_checkbox == expected_checkbox then
		return
	end

	-- ⭐ 替换复选框文本
	vim.api.nvim_buf_set_text(bufnr, row, start_col - 1, row, end_col, { expected_checkbox })

	-- ⭐ 自动保存（避免退出时提示未保存）
	autosave.request_save(bufnr)
end

---------------------------------------------------------------------
-- 状态 / 进度条构建
---------------------------------------------------------------------
local function task_to_link(task)
	if not task then
		return nil
	end

	return {
		id = task.id,
		status = task.core and task.core.status,
		previous_status = task.core and task.core.previous_status,
		created_at = task.timestamps and task.timestamps.created,
		updated_at = task.timestamps and task.timestamps.updated,
		completed_at = task.timestamps and task.timestamps.completed,
		archived_at = task.timestamps and task.timestamps.archived,
		archived_reason = task.timestamps and task.timestamps.archived_reason,
	}
end

local function build_status_display(task, parts)
	if not task then
		return parts
	end

	local link_obj = task._link
	if not link_obj and task.id then
		local t = core.get_task(task.id)
		if t then
			link_obj = task_to_link(t)
		end
	end

	if not link_obj then
		return parts
	end

	local components = status.get_display_components(link_obj)
	if not components then
		return parts
	end

	if components.icon and components.icon ~= "" then
		table.insert(parts, { "  ", "Normal" })
		table.insert(parts, { components.icon, components.icon_highlight })
	end

	if components.time and components.time ~= "" then
		table.insert(parts, { " ", "Normal" })
		table.insert(parts, { components.time, components.time_highlight })
	end

	return parts
end

local function build_progress_display(task, parts)
	if not task or not task.children or #task.children == 0 then
		return parts
	end

	local progress = core_stats.calc_group_progress(task)
	if not progress or progress.total <= 1 then
		return parts
	end

	local progress_virt = progress_render.build(progress)
	if progress_virt and #progress_virt > 0 then
		vim.list_extend(parts, progress_virt)
	end

	return parts
end

---------------------------------------------------------------------
-- 单任务增量渲染
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not task then
		return
	end

	-- ⭐ 行号以存储为权威
	local row = get_authoritative_row(task)
	if row < 0 then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local line = get_line_safe(bufnr, row)
	if not format.is_task_line(line) then
		return
	end

	-- ⭐ 自动对齐复选框 + 自动保存
	sync_checkbox_with_storage(bufnr, row, task)

	-- 重新获取行内容
	line = get_line_safe(bufnr, row)

	-- ⭐ 删除线（基于存储状态）
	local st = get_authoritative_status(task.id)
	local is_completed = st and types.is_completed_status(st)

	if is_completed then
		apply_completed_visuals(bufnr, row, #line)
	end

	-- ⭐ 状态图标 + 进度条
	local virt = {}
	virt = build_progress_display(task, virt)
	virt = build_status_display(task, virt)

	if #virt > 0 then
		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, -1, {
			virt_text = virt,
			virt_text_pos = "inline",
			hl_mode = "combine",
			right_gravity = true,
			priority = 100,
		})
	end

	-- conceal 增量刷新
	local ok, conceal = pcall(require, "todo2.render.conceal")
	if ok and conceal and conceal.apply_smart_conceal then
		pcall(conceal.apply_smart_conceal, bufnr, { row + 1 })
	end
end

---------------------------------------------------------------------
-- 递归渲染整棵任务树
---------------------------------------------------------------------
local function render_tree(bufnr, task)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

---------------------------------------------------------------------
-- 全量渲染入口
---------------------------------------------------------------------
function M.render(bufnr, opts)
	opts = opts or {}

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	local tasks, roots = scheduler.get_parse_tree(path, opts.force_refresh)

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	if not tasks or #tasks == 0 then
		return 0
	end

	core_stats.calculate_all_stats(tasks)

	for _, root in ipairs(roots) do
		pcall(render_tree, bufnr, root)
	end

	local ok, conceal = pcall(require, "todo2.render.conceal")
	if ok and conceal and conceal.apply_smart_conceal then
		pcall(conceal.apply_smart_conceal, bufnr)
	end

	return #tasks
end

---------------------------------------------------------------------
-- 清理接口
---------------------------------------------------------------------
function M.clear_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

function M.clear_all()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
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
