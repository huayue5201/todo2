-- lua/todo2/ui/render.lua
--- @module todo2.ui.render
--- @brief 渲染模块：基于核心解析器的权威任务树
--- ⭐ 简化版：每次都是全量清除，全量重新渲染，像 link/renderer.lua 一样简单可靠

local M = {}

-- FIX:ref:026cb0
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

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local NS = vim.api.nvim_create_namespace("todo2_render")
local DEBUG = false

---------------------------------------------------------------------
-- 缓存系统（只缓存解析树，不缓存渲染状态）
---------------------------------------------------------------------
local ParserCache = {
	trees = {},
	TREE_TTL = 5000,
}

--- 获取任务树（带缓存）
--- @param path string
--- @param force_refresh boolean
--- @return table[] tasks, table[] roots, table line_index
local function get_cached_task_tree(path, force_refresh)
	local now = vim.loop.now()
	local cached = ParserCache.trees[path]

	if not force_refresh and cached and (now - cached.timestamp) < ParserCache.TREE_TTL then
		return cached.tasks, cached.roots, cached.line_index
	end

	-- 重新解析
	local cfg = config.get("parser") or {}
	local tasks, roots

	if cfg.context_split then
		tasks, roots = parser.parse_main_tree(path, force_refresh)
	else
		tasks, roots = parser.parse_file(path, force_refresh)
	end

	tasks = tasks or {}
	roots = roots or {}

	-- 构建行号索引
	local line_index = {}
	for _, task in ipairs(tasks) do
		if task.line_num then
			line_index[task.line_num] = task
		end
	end

	-- 缓存结果
	ParserCache.trees[path] = {
		tasks = tasks,
		roots = roots,
		line_index = line_index,
		timestamp = now,
	}

	return tasks, roots, line_index
end

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

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

--- 获取行内容（安全）
--- @param bufnr integer
--- @param row integer 0-based
--- @return string
local function get_line_safe(bufnr, row)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if row < 0 or row >= line_count then
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

--- 构建已完成任务的视觉元素（删除线）
--- @param bufnr integer
--- @param row integer
--- @param line_len integer
local function apply_completed_visuals(bufnr, row, line_len)
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

--- 构建子任务进度显示（复用 core.stats）
--- @param task table 解析树中的任务
--- @param current_parts table 已有的虚拟文本部分
--- @return table 更新后的虚拟文本部分
local function build_progress_display(task, current_parts)
	-- 只有有子任务的任务才显示进度条
	if not task or not task.children or #task.children == 0 then
		return current_parts
	end

	-- ⭐ 直接复用 core.stats 的双轨统计
	local progress = core_stats.calc_group_progress(task)

	if progress.total <= 1 then
		return current_parts
	end

	-- 显示进度条（使用配置的样式）
	local style = config.get("progress_style") or 5

	table.insert(current_parts, { "  ", "Normal" })

	if style == 5 then
		local len = math.max(5, math.min(20, progress.total))
		local filled = math.floor(progress.percent / 100 * len)

		for _ = 1, filled do
			table.insert(current_parts, { "▰", "Todo2ProgressDone" })
		end
		for _ = filled + 1, len do
			table.insert(current_parts, { "▱", "Todo2ProgressTodo" })
		end

		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("%d%% (%d/%d)", progress.percent, progress.done, progress.total),
			"Todo2ProgressDone",
		})
	elseif style == 3 then
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("%d%%", progress.percent),
			"Todo2ProgressDone",
		})
	else
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("(%d/%d)", progress.done, progress.total),
			"Todo2ProgressDone",
		})
	end

	return current_parts
end

---------------------------------------------------------------------
-- 核心渲染函数 - 简化版（像 link/renderer.lua 一样）
---------------------------------------------------------------------

--- 渲染单个任务行
--- @param bufnr integer
--- @param task table
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not task then
		return
	end

	local row = (task.line_num or 1) - 1
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	if row < 0 or row >= line_count then
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

--- 递归渲染任务树
--- @param bufnr integer
--- @param task table
local function render_tree(bufnr, task)
	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

--- ⭐ 核心渲染函数 - 像 link/renderer.lua 一样简单
--- 每次都是：1. 先清除所有 2. 再重新渲染所有
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

	-- 获取任务树
	local tasks, roots = get_cached_task_tree(path, opts.force_refresh)

	-- ⭐ 第一步：先清除所有渲染（像 link/renderer.lua 一样）
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	if not tasks or #tasks == 0 then
		return 0
	end

	-- 计算统计信息（复用 core.stats）
	core_stats.calculate_all_stats(tasks)

	-- ⭐ 第二步：重新渲染所有任务（像 link/renderer.lua 一样）
	for _, root in ipairs(roots) do
		render_tree(bufnr, root)
	end

	if DEBUG then
		vim.notify(string.format("已渲染 %d 个任务", #tasks), vim.log.levels.DEBUG)
	end

	return #tasks
end

---------------------------------------------------------------------
-- 缓存管理
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

--- 清除解析器缓存
--- @param path string|nil
function M.clear_parser_cache(path)
	if path then
		ParserCache.trees[path] = nil
	else
		ParserCache.trees = {}
	end
end

M.clear = M.clear_all

return M
