-- lua/todo2/render/code_render.lua
-- 代码文件渲染：在代码行旁显示任务状态

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local progress_render = require("todo2.render.progress")
local file = require("todo2.utils.file")
local id_utils = require("todo2.utils.id")

local NS = vim.api.nvim_create_namespace("code_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---检查行号是否有效
---@param bufnr number
---@param row number
---@return boolean
local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

---动态截断长度（基于窗口宽度）
---@return number
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

---从代码行提取任务ID
---@param line string
---@return string?
local function extract_task_id(line)
	return id_utils.extract_id_from_code_mark(line)
end

---获取标签高亮组
---@param tag string
---@return string
local function get_tag_hl(tag)
	return "Todo2Tag_" .. (tag or "TODO")
end

---------------------------------------------------------------------
-- 单行渲染
---------------------------------------------------------------------

---渲染单行代码
---@param bufnr number
---@param row number
function M.render_line(bufnr, row)
	if not is_valid_line(bufnr, row) then
		return
	end

	local line = file.get_buf_line(bufnr, row + 1)
	if not line then
		return
	end

	local id = extract_task_id(line)
	if not id then
		return
	end

	local task = core.get_task(id)
	if not task then
		return
	end

	-- 清除该行的旧标记
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	-- 构建虚拟文本
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

	-- 进度条（如果有子任务）
	local child_ids = relation.get_child_ids(id)
	if #child_ids > 0 then
		local all_ids = { id }
		local descendants = relation.get_descendants(id)
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
			percent = math.floor(done / #all_ids * 100),
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
-- 文件渲染
---------------------------------------------------------------------

---渲染整个代码文件
---@param bufnr number
---@return number
function M.render_file(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local rendered = 0

	for row = 0, line_count - 1 do
		local line = file.get_buf_line(bufnr, row + 1)
		if line and extract_task_id(line) then
			M.render_line(bufnr, row)
			rendered = rendered + 1
		end
	end

	return rendered
end

---增量渲染
---@param bufnr number
---@param changed_ids string[]
---@return number
function M.render_changed(bufnr, changed_ids)
	if not vim.api.nvim_buf_is_valid(bufnr) or not changed_ids or #changed_ids == 0 then
		return 0
	end

	local rendered = 0
	for _, id in ipairs(changed_ids) do
		local location = core.get_code_location(id)
		if location and location.line then
			M.render_line(bufnr, location.line - 1)
			rendered = rendered + 1
		end
	end

	return rendered
end

---按任务ID渲染
---@param task_id string
function M.render_task_id(task_id)
	local location = core.get_code_location(task_id)
	if not location or not location.path or not location.line then
		return
	end

	-- 找到对应的缓冲区
	local bufnr = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == location.path then
			bufnr = b
			break
		end
	end

	if bufnr then
		M.render_line(bufnr, location.line - 1)
	end
end

---------------------------------------------------------------------
-- 清理接口
---------------------------------------------------------------------

---清理缓冲区
---@param bufnr number
function M.clear(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

return M
