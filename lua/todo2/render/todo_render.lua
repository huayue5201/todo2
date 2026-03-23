-- lua/todo2/render/todo_render.lua
-- 新世界版：结构来自 parser，状态来自存储，关系来自 relation
-- 职责：只负责视觉渲染，不修改缓冲区内容

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local progress_render = require("todo2.render.progress")
local scheduler = require("todo2.render.scheduler")
local file = require("todo2.utils.file")

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

local function apply_completed_visuals(bufnr, row, line_len)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
		end_row = row,
		end_col = line_len,
		hl_group = "TodoStrikethrough",
		hl_mode = "combine",
		priority = 200,
	})
end

local function build_status_display(task, parts)
	local link_obj = {
		id = task.id,
		status = task.core.status,
		previous_status = task.core.previous_status,
		created_at = task.timestamps.created,
		updated_at = task.timestamps.updated,
		completed_at = task.timestamps.completed,
		archived_at = task.timestamps.archived,
	}

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

local function build_progress_display(task_id, parts)
	local child_ids = relation.get_child_ids(task_id)
	if #child_ids == 0 then
		return parts
	end

	local all_ids = { task_id }
	local descendants = relation.get_descendants(task_id)
	vim.list_extend(all_ids, descendants)

	local done = 0
	for _, id in ipairs(all_ids) do
		local t = core.get_task(id)
		if t and types.is_completed_status(t.core.status) then
			done = done + 1
		end
	end

	local progress = {
		done = done,
		total = #all_ids,
		percent = math.floor(done / #all_ids * 100),
	}

	if progress.total <= 1 then
		return parts
	end

	local virt = progress_render.build(progress)
	if virt and #virt > 0 then
		vim.list_extend(parts, virt)
	end

	return parts
end

---------------------------------------------------------------------
-- 单任务渲染
---------------------------------------------------------------------

function M.render_task(bufnr, parsed_task)
	local id = parsed_task.id
	local line_num = parsed_task.line_num
	if not id or not line_num then
		return
	end

	local row = line_num - 1
	if row < 0 then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local line = get_line_safe(bufnr, row)
	if not format.is_task_line(line) then
		return
	end

	local task = core.get_task(id)
	if not task then
		-- 任务已被删除，清理渲染
		return
	end

	-- 完成状态视觉
	if types.is_completed_status(task.core.status) then
		apply_completed_visuals(bufnr, row, #line)
	end

	-- 构建虚拟文本
	local virt = {}
	virt = build_progress_display(id, virt)
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
end

---------------------------------------------------------------------
-- 文件渲染（结构来自 parser）
---------------------------------------------------------------------

function M.render(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = file.buf_path(bufnr)
	if path == "" then
		return 0
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local _, roots = scheduler.get_tasks_for_buf(bufnr)

	if #roots == 0 then
		return 0
	end

	local rendered = 0

	local function render_node(node)
		M.render_task(bufnr, node)
		rendered = rendered + 1
		for _, child in ipairs(node.children or {}) do
			render_node(child)
		end
	end

	for _, root in ipairs(roots) do
		render_node(root)
	end

	return rendered
end

---------------------------------------------------------------------
-- 增量渲染（直接使用 state_manager 推送的 IDs）
---------------------------------------------------------------------

function M.render_changed(bufnr, changed_ids)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	if not changed_ids or #changed_ids == 0 then
		return 0
	end

	local _, _, id_map = scheduler.get_tasks_for_buf(bufnr)

	local rendered = 0
	for _, id in ipairs(changed_ids) do
		local parsed = id_map[id]
		if parsed then
			M.render_task(bufnr, parsed)
			rendered = rendered + 1
		end
	end

	return rendered
end

---------------------------------------------------------------------
-- 清理接口
---------------------------------------------------------------------

function M.clear(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

return M
