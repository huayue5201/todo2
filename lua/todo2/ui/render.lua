-- lua/todo2/ui/render.lua
--- @module todo2.ui.render
--- @brief 渲染模块：基于核心解析器的权威任务树，支持上下文隔离
---
--- 优化版本：
--- 1. 引入渲染缓存，避免重复渲染
--- 2. 支持增量更新（只渲染变化的行）
--- 3. 分离数据获取、状态计算、视觉渲染
--- 4. 添加详细的性能日志（调试用）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
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
local DEBUG = false -- 调试开关

---------------------------------------------------------------------
-- 缓存系统
---------------------------------------------------------------------
local RenderCache = {
	-- 行渲染缓存: bufnr -> { [line_num] = hash }
	lines = {},

	-- 任务树缓存: path -> { tasks, roots, timestamp }
	trees = {},

	-- 缓存有效期（毫秒）
	TREE_TTL = 5000, -- 5秒
}

--- 计算行的渲染哈希值
--- @param task table 任务对象
--- @param line string 当前行内容
--- @return string 哈希值
local function compute_line_hash(task, line)
	if not task then
		return "nil"
	end

	-- 组合影响渲染的关键因素
	local parts = {
		task.line_num or 0,
		task.status or "normal",
		task.id or "",
		task.stats and (task.stats.done or 0) or 0,
		task.stats and (task.stats.total or 0) or 0,
		line:match("%[([ xX>])%]") or "", -- 复选框状态
	}

	return table.concat(parts, "|")
end

--- 检查行是否需要重新渲染
--- @param bufnr integer
--- @param line_num integer
--- @param task table
--- @param line string
--- @return boolean 需要渲染返回 true
local function should_render_line(bufnr, line_num, task, line)
	if not RenderCache.lines[bufnr] then
		RenderCache.lines[bufnr] = {}
	end

	local new_hash = compute_line_hash(task, line)
	local old_hash = RenderCache.lines[bufnr][line_num]

	if old_hash == new_hash then
		if DEBUG then
			log.debug(string.format("跳过渲染行 %d (无变化)", line_num))
		end
		return false
	end

	-- 更新缓存
	RenderCache.lines[bufnr][line_num] = new_hash
	return true
end

--- 获取任务树（带缓存）
--- @param path string
--- @param force_refresh boolean
--- @return table[] tasks, table[] roots, table line_index
local function get_cached_task_tree(path, force_refresh)
	local now = vim.loop.now()
	local cached = RenderCache.trees[path]

	if not force_refresh and cached and (now - cached.timestamp) < RenderCache.TREE_TTL then
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
	RenderCache.trees[path] = {
		tasks = tasks,
		roots = roots,
		line_index = line_index,
		timestamp = now,
	}

	return tasks, roots, line_index
end

--- 获取任务的权威状态（从 store.link 验证）
--- @param task_id string
--- @return string|nil
local function get_authoritative_status(task_id)
	if not link or not task_id then
		return nil
	end
	local todo_link = link.get_todo(task_id, { verify_line = true })
	return todo_link and todo_link.status or nil
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
	-- 删除线高亮（覆盖整行）
	pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
		end_row = row,
		end_col = line_len,
		hl_group = "TodoStrikethrough",
		hl_mode = "combine",
		priority = 200,
	})

	-- 附加完成颜色
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
	if not task_id or not link then
		return current_parts
	end

	local link_obj = link.get_todo(task_id, { verify_line = true })
	if not link_obj or not status then
		return current_parts
	end

	local components = status.get_display_components(link_obj)
	if not components then
		return current_parts
	end

	-- 添加状态图标
	if components.icon and components.icon ~= "" then
		if #current_parts > 0 then
			table.insert(current_parts, { " ", "Normal" })
		end
		table.insert(current_parts, { components.icon, components.icon_highlight })
	end

	-- 添加时间显示
	if components.time and components.time ~= "" then
		if #current_parts > 0 then
			table.insert(current_parts, { " ", "Normal" })
		end
		table.insert(current_parts, { components.time, components.time_highlight })
	end

	return current_parts
end

--- 构建子任务进度显示
--- @param task table
--- @param current_parts table 已有的虚拟文本部分
--- @return table 更新后的虚拟文本部分
local function build_progress_display(task, current_parts)
	if not task.children or #task.children == 0 or not task.stats then
		return current_parts
	end

	local done = task.stats.done or 0
	local total = task.stats.total or #task.children

	if total > 0 then
		if #current_parts > 0 then
			table.insert(current_parts, { " ", "Normal" })
		end
		table.insert(current_parts, {
			string.format("(%d/%d)", math.floor(done), math.floor(total)),
			"Comment",
		})
	end

	return current_parts
end

---------------------------------------------------------------------
-- 核心渲染函数
---------------------------------------------------------------------

--- 渲染单个任务行
--- @param bufnr integer
--- @param task table
--- @param line_index table 行号索引（用于查找相关任务）
function M.render_task(bufnr, task, line_index)
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

	-- 检查是否需要渲染
	if not should_render_line(bufnr, task.line_num, task, line) then
		return
	end

	-- 清除该行的旧渲染
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	-- 获取权威状态
	local authoritative_status = nil
	if task.id then
		authoritative_status = get_authoritative_status(task.id)
	end
	local is_completed = authoritative_status and types.is_completed_status(authoritative_status) or false

	-- 应用完成状态视觉元素
	if is_completed then
		apply_completed_visuals(bufnr, row, line_len)
	end

	-- 构建虚拟文本
	local virt_text_parts = {}

	-- 添加进度显示
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

	if DEBUG then
		log.debug(string.format("已渲染行 %d (任务: %s)", task.line_num, task.id or "无ID"))
	end
end

--- 递归渲染任务树
--- @param bufnr integer
--- @param task table
--- @param line_index table
local function render_tree(bufnr, task, line_index)
	M.render_task(bufnr, task, line_index)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child, line_index)
	end
end

--- 渲染变化的行（增量更新）
--- @param bufnr integer
--- @param changed_lines table 行号列表（1-based）
--- @param line_index table 行号索引
function M.render_changed_lines(bufnr, changed_lines, line_index)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not changed_lines then
		return 0
	end

	local rendered_count = 0
	for _, lnum in ipairs(changed_lines) do
		local task = line_index and line_index[lnum]
		if task then
			M.render_task(bufnr, task, line_index)
			rendered_count = rendered_count + 1
		end
	end

	return rendered_count
end

---------------------------------------------------------------------
-- 对外渲染接口
---------------------------------------------------------------------

--- 渲染整个缓冲区
--- @param bufnr integer
--- @param opts table
---   - force_refresh: boolean 是否强制刷新解析缓存
---   - changed_lines: table 只渲染指定的行（增量更新）
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

	-- 获取任务树（带缓存）
	local tasks, roots, line_index = get_cached_task_tree(path, opts.force_refresh)

	if not tasks or #tasks == 0 then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		return 0
	end

	-- 计算统计信息
	core_stats.calculate_all_stats(tasks)

	-- 增量更新或全量更新
	if opts.changed_lines and #opts.changed_lines > 0 then
		-- 只渲染变化的行
		return M.render_changed_lines(bufnr, opts.changed_lines, line_index)
	else
		-- 全量更新：先清除所有，再重新渲染
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

		-- 清空该缓冲区的行缓存
		if RenderCache.lines[bufnr] then
			RenderCache.lines[bufnr] = {}
		end

		for _, root in ipairs(roots) do
			render_tree(bufnr, root, line_index)
		end

		return #tasks
	end
end

---------------------------------------------------------------------
-- 缓存管理
---------------------------------------------------------------------

--- 清除指定缓冲区的渲染缓存
--- @param bufnr integer
function M.clear_buffer_cache(bufnr)
	if bufnr then
		RenderCache.lines[bufnr] = nil

		-- 清除 extmark
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end
end

--- 清除所有缓存
--- @param refresh_parser boolean 是否同时刷新解析缓存
function M.clear_cache(refresh_parser)
	-- 清除行渲染缓存
	RenderCache.lines = {}

	-- 清除任务树缓存
	RenderCache.trees = {}

	-- 清除所有缓冲区的 extmark
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end

	-- 按需刷新解析缓存
	if refresh_parser then
		parser.invalidate_cache()
	end

	if DEBUG then
		log.debug("所有渲染缓存已清除")
	end
end

--- 获取缓存统计信息（调试用）
function M.get_cache_stats()
	local stats = {
		buffers_with_cache = 0,
		total_cached_lines = 0,
		cached_trees = vim.tbl_count(RenderCache.trees),
	}

	for bufnr, lines in pairs(RenderCache.lines) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			stats.buffers_with_cache = stats.buffers_with_cache + 1
			stats.total_cached_lines = stats.total_cached_lines + vim.tbl_count(lines)
		else
			-- 清理无效缓冲区的缓存
			RenderCache.lines[bufnr] = nil
		end
	end

	return stats
end

--- 兼容旧接口
M.clear = M.clear_cache

return M
