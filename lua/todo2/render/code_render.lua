-- lua/todo2/render/code_render.lua
-- 代码文件渲染：基于存储，在代码行旁显示任务状态

local M = {}

local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local task_virt = require("todo2.render.task_virt")
local constants = require("todo2.constants")

local NS = constants.ns("code_render")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 根据当前窗口宽度计算任务内容的动态截断长度.
--- 以窗口宽度的 40% 为基准，并限制在 [20, 60] 区间内。
---@return number 截断长度（字符数）
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

--- 获取指定标签对应的高亮组名.
---@param tag string|nil 标签名，nil 时按 "TODO" 处理
---@return string 高亮组名，形如 "Todo2Tag_TODO"
local function get_tag_hl(tag)
	return "Todo2Tag_" .. (tag or "TODO")
end

---------------------------------------------------------------------
-- 单行渲染
---------------------------------------------------------------------

--- 在指定缓冲区的一行上渲染单个任务的状态信息.
--- 渲染内容包括：复选框图标、任务内容、子任务进度条、状态图标与时间。
--- 会先清除该行的旧标记，再写入新的 extmark 虚拟文本。
---@param bufnr number 缓冲区号
---@param row number 行号（0-based）
---@param task table|nil 任务对象，nil 时直接返回
function M.render_line(bufnr, row, task)
	if not task then
		return
	end

	-- 清除旧标记
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	local virt = {}

	-- 是否完成（只算一次）
	local completed = types.is_completed_status(task.core.status)

	-- 复选框图标
	local icon = completed and "✓" or "◻"
	local icon_hl = completed and "Todo2StatusDone" or "Todo2StatusTodo"
	table.insert(virt, {
		" " .. icon,
		icon_hl,
	})

	-- 任务内容
	local content = task.core.content or ""
	if content ~= "" then
		local truncate_len = get_dynamic_truncate_length()
		local text = format.truncate and format.truncate(content, truncate_len) or content
		local hl = completed and "TodoStrikethrough" or get_tag_hl(task.core.tags[1])
		table.insert(virt, { " " .. text, hl })
	end

	-- 子任务进度条 + 状态图标（统一由 task_virt 构建）
	task_virt.build_progress(task.id, virt)
	task_virt.build_status(task, virt)

	if #virt > 0 then
		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, -1, {
			virt_text = virt,
			virt_text_pos = "inline",
			sign_text = icon,
			sign_hl_group = icon_hl,
			hl_mode = "combine",
			right_gravity = true,
			priority = 50,
		})
	end
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------

--- 对指定缓冲区进行全量任务渲染.
--- 先清空命名空间下的所有标记，再遍历该文件关联的所有任务并逐行渲染。
---@param bufnr number 缓冲区号
---@return number 实际渲染的任务数量
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

--- 对指定缓冲区进行增量渲染，仅处理发生变化的任务及被删除的位置.
---@param bufnr number 缓冲区号
---@param changed_ids string[]|nil 发生变化的任务 ID 列表
---@param deleted_locations table[]|nil 被删除的位置列表，每项含 path、line 字段
---@return number 实际渲染的任务数量
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
-- 清理接口
---------------------------------------------------------------------

--- 清除指定缓冲区中由本模块写入的所有渲染标记.
---@param bufnr number 缓冲区号
function M.clear(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

return M
