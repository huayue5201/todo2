-- lua/todo2/render/code_render.lua
-- 代码文件渲染：基于存储，在代码行旁显示任务状态

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local progress_render = require("todo2.render.progress")
local index = require("todo2.store.index")

local NS = vim.api.nvim_create_namespace("code_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function get_dynamic_truncate_length()
	local win = vim.api.nvim_get_current_win()
	if not win or win == 0 then
		return 40
	end

	local width = vim.api.nvim_win_get_width(win)
	if not width or width <= 0 then
		return 40
	end

	local len = math.floor(width * 0.4)
	if len < 20 then
		len = 20
	end
	if len > 60 then
		len = 60
	end
	return len
end

local function get_tag_hl(tag)
	return "Todo2Tag_" .. (tag or "TODO")
end

---------------------------------------------------------------------
-- 单行渲染
---------------------------------------------------------------------

function M.render_line(bufnr, row, task)
	if not task then
		return
	end

	-- 清除旧标记
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local virt = {}

	-- 复选框图标
	local icon = types.is_completed_status(task.core.status) and "✓" or "◻"
	table.insert(virt, {
		" " .. icon,
		types.is_completed_status(task.core.status) and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- 任务内容
	local content = task.core.content or ""
	if content ~= "" then
		local truncate_len = get_dynamic_truncate_length()
		local text = format.truncate and format.truncate(content, truncate_len) or content
		local hl = types.is_completed_status(task.core.status) and "TodoStrikethrough" or get_tag_hl(task.core.tags[1])
		table.insert(virt, { " " .. text, hl })
	end

	-- 进度条
	local child_ids = relation.get_child_ids(task.id)
	if #child_ids > 0 then
		local all_ids = { task.id }
		local descendants = relation.get_descendants(task.id)
		vim.list_extend(all_ids, descendants)

		local done = 0
		for _, tid in ipairs(all_ids) do
			local t = core.get_task(tid)
			if t and types.is_completed_status(t.core.status) then
				done = done + 1
			end
		end

		local progress = {
			done = done,
			total = #all_ids,
			percent = #all_ids > 0 and math.floor(done / #all_ids * 100) or 0,
		}

		if progress.total > 1 then
			local progress_virt = progress_render.build(progress)
			vim.list_extend(virt, progress_virt)
		end
	end

	-- 状态图标
	local link = {
		id = task.id,
		status = task.core.status,
		created_at = task.timestamps.created,
		updated_at = task.timestamps.updated,
		completed_at = task.timestamps.completed,
	}

	local components = status.get_display_components(link)
	if components then
		if components.icon and components.icon ~= "" then
			table.insert(virt, { "  ", "Normal" })
			table.insert(virt, { components.icon, components.icon_highlight or "Normal" })
		end
		if components.time and components.time ~= "" then
			table.insert(virt, { " ", "Normal" })
			table.insert(virt, { components.time, components.time_highlight or "Normal" })
		end
	end

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
-- 全量渲染
---------------------------------------------------------------------

function M.render_file(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local path = vim.api.nvim_buf_get_name(bufnr)
	local tasks = index.find_code_links_by_file(path)
	local rendered = 0

	for _, task in ipairs(tasks) do
		if task.locations.code then
			local line = task.locations.code.line
			if line >= 1 and line <= vim.api.nvim_buf_line_count(bufnr) then
				M.render_line(bufnr, line - 1, task)
				rendered = rendered + 1
			end
		end
	end

	return rendered
end

---------------------------------------------------------------------
-- 增量渲染
---------------------------------------------------------------------

function M.render_changed(bufnr, changed_ids, deleted_locations)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	local rendered = 0

	-- 1. 处理删除的位置
	if deleted_locations and #deleted_locations > 0 then
		for _, loc in ipairs(deleted_locations) do
			if loc.path == path then
				vim.api.nvim_buf_clear_namespace(bufnr, NS, loc.line - 1, loc.line)
			end
		end
	end

	-- 2. 处理需要渲染的任务
	if changed_ids and #changed_ids > 0 then
		local id_set = {}
		for _, id in ipairs(changed_ids) do
			id_set[id] = true
		end

		local tasks = index.find_code_links_by_file(path)
		for _, task in ipairs(tasks) do
			if id_set[task.id] and task.locations.code then
				local line = task.locations.code.line
				if line >= 1 and line <= vim.api.nvim_buf_line_count(bufnr) then
					M.render_line(bufnr, line - 1, task)
					rendered = rendered + 1
				end
			end
		end
	end

	return rendered
end

---------------------------------------------------------------------
-- 按任务 ID 渲染
---------------------------------------------------------------------

function M.render_task_id(task_id)
	local location = core.get_code_location(task_id)
	if not location or not location.path or not location.line then
		return
	end

	local bufnr = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == location.path then
			bufnr = b
			break
		end
	end

	if bufnr then
		local task = core.get_task(task_id)
		if task then
			M.render_line(bufnr, location.line - 1, task)
		end
	end
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
