-- lua/todo2/ui/render.lua
--- @module todo2.ui.render
--- @brief 渲染模块：基于核心解析器的权威任务树，支持上下文隔离

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

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local NS = vim.api.nvim_create_namespace("todo2_render")
local DEBUG = false

---------------------------------------------------------------------
-- 缓存系统
---------------------------------------------------------------------
local RenderCache = {
	lines = {},
	trees = {},
	TREE_TTL = 5000,
}

--- 计算行的渲染哈希值
--- @param task table 任务对象
--- @param line string 当前行内容
--- @param authoritative_status string|nil 权威状态
--- @return string 哈希值
local function compute_line_hash(task, line, authoritative_status)
	if not task then
		return "nil"
	end

	local stats = task.stats or {}
	local status_to_use = authoritative_status or task.status or "normal"

	local parts = {
		task.line_num or 0,
		status_to_use,
		task.id or "",
		stats.done or 0,
		stats.total or 0,
		line:match("%[([ xX>])%]") or "",
	}

	return table.concat(parts, "|")
end

--- 检查行是否需要重新渲染
--- @param bufnr integer
--- @param line_num integer
--- @param task table
--- @param line string
--- @param authoritative_status string|nil
--- @return boolean
local function should_render_line(bufnr, line_num, task, line, authoritative_status)
	if not RenderCache.lines[bufnr] then
		RenderCache.lines[bufnr] = {}
	end

	local new_hash = compute_line_hash(task, line, authoritative_status)
	local old_hash = RenderCache.lines[bufnr][line_num]

	if old_hash == new_hash then
		if DEBUG then
			vim.notify(string.format("跳过渲染行 %d (无变化)", line_num), vim.log.levels.DEBUG)
		end
		return false
	end

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

--- ⭐ 构建任务状态图标和时间显示（使用权威状态）
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

	-- ⭐ 新增：添加上下文状态指示
	if link_obj.context then
		if link_obj.context_valid == false then
			table.insert(current_parts, { " ", "Normal" })
			table.insert(current_parts, { "⚠️", "TodoContextInvalid" })
		elseif link_obj.context_similarity and link_obj.context_similarity < 80 then
			table.insert(current_parts, { " ", "Normal" })
			table.insert(
				current_parts,
				{ string.format("🔍%d%%", link_obj.context_similarity), "TodoContextExpired" }
			)
		end
	end

	return current_parts
end

--- ⭐ 构建子任务进度显示（使用权威状态）
--- @param task table 解析树中的任务
--- @param current_parts table 已有的虚拟文本部分
--- @return table 更新后的虚拟文本部分
local function build_progress_display(task, current_parts)
	-- 只有有子任务的任务才显示进度条
	if not task or not task.children or #task.children == 0 then
		return current_parts
	end

	-- 从存储获取权威状态
	local function get_task_status_from_store(task_id)
		if not task_id then
			return nil
		end
		local todo_link = link.get_todo(task_id, { verify_line = false })
		return todo_link and todo_link.status or nil
	end

	-- 递归计算子任务的完成情况
	local function count_children(node)
		local done = 0
		local total = 0

		for _, child in ipairs(node.children or {}) do
			total = total + 1
			local status = get_task_status_from_store(child.id) or child.status
			if status == types.STATUS.COMPLETED then
				done = done + 1
			end

			-- 递归统计孙任务
			local child_done, child_total = count_children(child)
			done = done + child_done
			total = total + child_total
		end

		return done, total
	end

	local done, total = count_children(task)

	if total == 0 then
		return current_parts
	end

	local percent = math.floor(done / total * 100)

	-- 显示进度条（使用配置的样式）
	local style = config.get("progress_style") or 5

	table.insert(current_parts, { "  ", "Normal" })

	if style == 5 then
		local len = math.max(5, math.min(20, total))
		local filled = math.floor(percent / 100 * len)

		for _ = 1, filled do
			table.insert(current_parts, { "▰", "Todo2ProgressDone" })
		end
		for _ = filled + 1, len do
			table.insert(current_parts, { "▱", "Todo2ProgressTodo" })
		end

		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("%d%% (%d/%d)", percent, done, total),
			"Todo2ProgressDone",
		})
	elseif style == 3 then
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("%d%%", percent),
			"Todo2ProgressDone",
		})
	else
		table.insert(current_parts, { " ", "Normal" })
		table.insert(current_parts, {
			string.format("(%d/%d)", done, total),
			"Todo2ProgressDone",
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
--- @param line_index table 行号索引
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

	-- 获取权威状态
	local authoritative_status = nil
	local is_completed = false
	local context_valid = nil
	local context_similarity = nil

	if task.id then
		authoritative_status = get_authoritative_status(task.id)
		is_completed = authoritative_status and types.is_completed_status(authoritative_status) or false

		-- ⭐ 获取上下文信息
		local link_obj = get_authoritative_link(task.id)
		if link_obj and link_obj.context then
			context_valid = link_obj.context_valid
			context_similarity = link_obj.context_similarity
		end
	end

	-- 检查是否需要渲染
	if not should_render_line(bufnr, task.line_num, task, line, authoritative_status) then
		return
	end

	-- 清除该行的旧渲染
	vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)

	-- 应用完成状态视觉元素
	if is_completed then
		apply_completed_visuals(bufnr, row, line_len)
	end

	-- ⭐ 如果上下文无效，添加特殊视觉标记
	if context_valid == false then
		-- 可以在行首或行尾添加标记
		vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
			virt_text = { { "⚠️ ", "TodoContextInvalid" } },
			virt_text_pos = "right_align",
			priority = 350,
		})
	elseif context_similarity and context_similarity < 80 then
		vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
			virt_text = { { string.format(" 🔍%d%%", context_similarity), "TodoContextExpired" } },
			virt_text_pos = "right_align",
			priority = 350,
		})
	end

	-- 构建虚拟文本
	local virt_text_parts = {}

	-- 添加进度显示
	virt_text_parts = build_progress_display(task, virt_text_parts)

	-- 添加状态和时间显示（包含上下文指示）
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
		vim.notify(
			string.format(
				"已渲染行 %d (任务: %s, 状态: %s, 上下文: %s)",
				task.line_num,
				task.id or "无ID",
				authoritative_status or "unknown",
				context_valid == false and "无效"
					or (context_similarity and string.format("%d%%", context_similarity) or "正常")
			),
			vim.log.levels.DEBUG
		)
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

	-- 计算统计信息（基于解析树）
	core_stats.calculate_all_stats(tasks)

	-- 增量更新或全量更新
	if opts.changed_lines and #opts.changed_lines > 0 then
		return M.render_changed_lines(bufnr, opts.changed_lines, line_index)
	else
		-- 全量更新：先清除所有，再重新渲染
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

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

		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end
end

--- 清除所有缓存
--- @param refresh_parser boolean 是否同时刷新解析缓存
function M.clear_cache(refresh_parser)
	RenderCache.lines = {}
	RenderCache.trees = {}

	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
		end
	end

	if refresh_parser then
		parser.invalidate_cache()
	end

	if DEBUG then
		vim.notify("所有渲染缓存已清除", vim.log.levels.DEBUG)
	end
end

--- 获取缓存统计信息
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
			RenderCache.lines[bufnr] = nil
		end
	end

	return stats
end

M.clear = M.clear_cache

return M
