-- lua/todo2/render/todo_render.lua
-- 基于存储渲染：从行提取 ID，从 core 获取任务数据

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local progress_render = require("todo2.render.progress")

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

---从行内容提取任务ID（支持多种格式）
---@param line string
---@return string|nil
local function extract_id_from_line(line)
	if not line then
		return nil
	end

	-- 格式1: {:ref:abc123}
	local id = line:match("{:ref:([a-f0-9]+)}")
	if id then
		return id
	end

	-- 格式2: {#abc123}（旧格式）
	id = line:match("{%#([^}]+)}")
	if id then
		return id
	end

	-- 格式3: 使用 parser 解析（兼容所有格式）
	local parsed = format.parse_task_line(line)
	if parsed and parsed.id then
		return parsed.id
	end

	return nil
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
		percent = #all_ids > 0 and math.floor(done / #all_ids * 100) or 0,
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

---渲染单个任务（基于存储）
---@param bufnr number
---@param line_num number 行号（1-indexed）
---@param line string 行内容
function M.render_task_by_line(bufnr, line_num, line)
	local id = extract_id_from_line(line)
	if not id then
		return
	end

	local row = line_num - 1
	if row < 0 then
		return
	end

	local task = core.get_task(id)
	if not task then
		-- 任务不存在，清理渲染
		vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)
		return
	end

	-- 清除旧标记
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

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

-- 保留旧接口兼容性
function M.render_task(bufnr, parsed_task)
	if parsed_task and parsed_task.line_num then
		local line = get_line_safe(bufnr, parsed_task.line_num - 1)
		if line and line ~= "" then
			M.render_task_by_line(bufnr, parsed_task.line_num, line)
		elseif parsed_task.id then
			-- 如果无法获取行，尝试从存储获取内容（降级方案）
			local task = core.get_task(parsed_task.id)
			if task and task.core.content then
				-- 至少可以渲染状态
				local row = parsed_task.line_num - 1
				vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)
				local virt = build_status_display(task, {})
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
		end
	end
end

---------------------------------------------------------------------
-- 文件渲染
---------------------------------------------------------------------

function M.render(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- 清理整个缓冲区
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local rendered = 0

	for i, line in ipairs(lines) do
		-- 检查是否为任务行
		if format.is_task_line(line) then
			M.render_task_by_line(bufnr, i, line)
			rendered = rendered + 1
		end
	end

	return rendered
end

---------------------------------------------------------------------
-- 增量渲染
---------------------------------------------------------------------

function M.render_changed(bufnr, changed_ids)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	if not changed_ids or #changed_ids == 0 then
		return 0
	end

	-- 构建 ID 集合用于快速查找
	local id_set = {}
	for _, id in ipairs(changed_ids) do
		id_set[id] = true
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local rendered = 0

	for i, line in ipairs(lines) do
		if format.is_task_line(line) then
			local id = extract_id_from_line(line)
			if id and id_set[id] then
				M.render_task_by_line(bufnr, i, line)
				rendered = rendered + 1
			end
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
