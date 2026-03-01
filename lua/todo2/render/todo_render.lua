-- lua/todo2/render/todo_render.lua
-- 只修改渲染函数，增加行号有效性检查

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local config = require("todo2.config")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local status = require("todo2.status")
local core_stats = require("todo2.core.stats")
local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local NS = vim.api.nvim_create_namespace("todo2_render")
local DEBUG = false

---------------------------------------------------------------------
-- ⭐ 新增：行号有效性检查
---------------------------------------------------------------------
local function is_valid_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return row >= 0 and row < line_count
end

---------------------------------------------------------------------
-- ⭐ 修改：使用调度器的缓存
---------------------------------------------------------------------
--- 获取任务树（使用调度器共享缓存）
--- @param path string
--- @param force_refresh boolean
--- @return table[] tasks, table[] roots, table line_index
local function get_cached_task_tree(path, force_refresh)
	-- 直接从调度器获取
	local tasks, roots, id_to_task = scheduler.get_parse_tree(path, force_refresh)

	-- 构建行号索引
	local line_index = {}
	for _, task in ipairs(tasks or {}) do
		if task and task.line_num then
			line_index[task.line_num] = task
		end
	end

	return tasks or {}, roots or {}, line_index
end

--- 获取任务的权威状态（从 store.link 获取）
--- @param task_id string
--- @return string|nil
local function get_authoritative_status(task_id)
	if not link or not task_id then
		return nil
	end
	local todo_link = link.get_todo(task_id, { verify_line = true })
	return todo_link and todo_link.status or nil
end

--- 获取任务的权威信息（完整）
--- @param task_id string
--- @return table|nil
local function get_authoritative_link(task_id)
	if not link or not task_id then
		return nil
	end
	return link.get_todo(task_id, { verify_line = true })
end

--- ⭐ 获取行内容（安全，增加行号有效性检查）
--- @param bufnr integer
--- @param row integer 0-based
--- @return string
local function get_line_safe(bufnr, row)
	-- ⭐ 先检查行号有效性
	if not is_valid_line(bufnr, row) then
		return ""
	end
	return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

--- 从行中提取任务 ID（备用）
--- @param line string
--- @return string|nil
local function extract_task_id(line)
	return format.extract_id(line)
end

--- ⭐ 构建已完成任务的视觉元素（增加行号有效性检查）
--- @param bufnr integer
--- @param row integer
--- @param line_len integer
local function apply_completed_visuals(bufnr, row, line_len)
	-- ⭐ 再次检查行号有效性
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

--- 构建任务状态图标和时间显示
--- @param task_id string
--- @param current_parts table 已有的虚拟文本部分
--- @return table 更新后的虚拟文本部分
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

	-- 添加状态图标
	if components.icon and components.icon ~= "" then
		table.insert(current_parts, { "  ", "Normal" })
		table.insert(current_parts, { components.icon, components.icon_highlight })
	end

	-- 添加时间显示
	if components.time and components.time ~= "" then
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, { components.time, components.time_highlight })
	end

	return current_parts
end

--- 构建子任务进度显示（使用配置模块）
--- @param task table 解析树中的任务
--- @param current_parts table 已有的虚拟文本部分
--- @return table 更新后的虚拟文本部分
local function build_progress_display(task, current_parts)
	-- 只有有子任务的任务才显示进度条
	if not task or not task.children or #task.children == 0 then
		return current_parts
	end

	-- 直接复用 core.stats 的双轨统计
	local progress = core_stats.calc_group_progress(task)

	if progress.total <= 1 then
		return current_parts
	end

	-- ⭐ 使用配置模块格式化进度条
	local progress_virt = config.format_progress_bar(progress)
	vim.list_extend(current_parts, progress_virt)

	return current_parts
end

---------------------------------------------------------------------
-- ⭐ 核心修复：渲染单个任务行（增加行号有效性检查）
---------------------------------------------------------------------

--- 渲染单个任务行
--- @param bufnr integer
--- @param task table
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not task then
		return
	end

	local row = (task.line_num or 1) - 1

	-- ⭐ 检查行号是否有效
	if not is_valid_line(bufnr, row) then
		return
	end

	local line = get_line_safe(bufnr, row)
	local line_len = #line

	-- 检查这一行是否仍然是任务行
	if not format.is_task_line(line) then
		-- 如果不是任务行，不渲染
		return
	end

	-- 获取权威状态
	local authoritative_status = nil
	local is_completed = false

	if task.id then
		authoritative_status = get_authoritative_status(task.id)
		is_completed = authoritative_status and types.is_completed_status(authoritative_status) or false
	end

	-- 应用完成状态视觉元素
	if is_completed then
		apply_completed_visuals(bufnr, row, line_len)
	end

	-- 构建虚拟文本
	local virt_text_parts = {}

	-- 添加进度显示（复用 core.stats）
	virt_text_parts = build_progress_display(task, virt_text_parts)

	-- 添加状态和时间显示
	local task_id = task.id or extract_task_id(line)
	virt_text_parts = build_status_display(task_id, virt_text_parts)

	-- 应用虚拟文本
	if #virt_text_parts > 0 then
		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, -1, {
			virt_text = virt_text_parts,
			virt_text_pos = "inline",
			hl_mode = "combine",
			right_gravity = true,
			priority = 300,
		})
	end
end

--- ⭐ 递归渲染任务树（增加buffer有效性检查）
--- @param bufnr integer
--- @param task table
local function render_tree(bufnr, task)
	-- 在递归前检查buffer是否仍然有效
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

---------------------------------------------------------------------
-- ⭐ 核心修复：渲染函数（增加动态行数获取）
---------------------------------------------------------------------

--- ⭐ 核心渲染函数
--- @param bufnr integer
--- @param opts table
---   - force_refresh: boolean 是否强制刷新解析缓存
--- @return integer 渲染的任务总数
function M.render(bufnr, opts)
	opts = opts or {}

	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end

	-- ⭐ 使用修改后的缓存获取函数
	local tasks, roots = get_cached_task_tree(path, opts.force_refresh)

	-- 第一步：先清除所有渲染
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	if not tasks or #tasks == 0 then
		return 0
	end

	-- ⭐ 动态获取当前行数
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	vim.b[bufnr].todo2_last_line_count = line_count

	-- 计算统计信息（复用 core.stats）
	core_stats.calculate_all_stats(tasks)

	-- 第二步：重新渲染所有任务
	for _, root in ipairs(roots) do
		-- 使用pcall防止单个任务渲染错误影响整体
		pcall(render_tree, bufnr, root)
	end

	if DEBUG then
		vim.notify(string.format("已渲染 %d 个任务", #tasks), vim.log.levels.DEBUG)
	end

	return #tasks
end

---------------------------------------------------------------------
-- 缓存管理（保留，但内部调用调度器）
---------------------------------------------------------------------

--- 清除指定缓冲区的渲染
--- @param bufnr integer
function M.clear_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

--- 清除所有渲染
function M.clear_all()
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end
end

--- 清除解析器缓存（转发到调度器）
--- @param path string|nil
function M.clear_parser_cache(path)
	scheduler.invalidate_cache(path)
end

M.clear = M.clear_all

return M
