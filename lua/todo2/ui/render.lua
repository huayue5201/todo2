-- lua/todo2/ui/render.lua
--- @module todo2.ui.render
--- @brief 渲染模块：基于核心解析器的权威任务树，支持上下文隔离

local M = {}

---------------------------------------------------------------------
-- 依赖加载
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local config = require("todo2.config")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local module = require("todo2.module")

---------------------------------------------------------------------
-- 命名空间（仅此一处定义）
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------
--- 安全获取缓冲区行内容
local function get_line(bufnr, row)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if row < 0 or row >= line_count then
		return ""
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

--- 从行中提取任务 ID（备用方案）
local function extract_task_id_from_line(line)
	return format.extract_id(line)
end

--- 获取任务的权威状态（从 store.link 验证）
local function get_task_authoritative_status(task_id)
	local link_mod = module.get("store.link")
	if not link_mod then
		return nil
	end
	local todo_link = link_mod.get_todo(task_id, { verify_line = true })
	return todo_link and todo_link.status or nil
end

--- 为任务列表构建行号→任务对象的快速索引
--- @param tasks table[] 任务列表
--- @return table<integer, table>
local function build_line_index(tasks)
	local idx = {}
	for _, task in ipairs(tasks) do
		if task.line_num then
			idx[task.line_num] = task
		end
	end
	return idx
end

--- 根据当前配置获取待渲染的任务树
--- @param path string 文件路径
--- @param force_refresh boolean 是否强制刷新缓存
--- @return table[] tasks 任务列表
--- @return table[] roots 根任务列表
--- @return table<integer, table> line_index 行号索引
local function get_tasks_for_render(path, force_refresh)
	local cfg = config.get("parser") or {}
	local tasks, roots, id_map

	if cfg.context_split then
		-- 启用归档隔离：只渲染主任务树（活动任务）
		tasks, roots, id_map = parser.parse_main_tree(path, force_refresh)
	else
		-- 兼容模式：渲染完整任务树（旧行为）
		tasks, roots, id_map = parser.parse_file(path, force_refresh)
	end

	-- 确保返回有效值
	tasks = tasks or {}
	roots = roots or {}

	-- 构建行号索引（用于增量渲染定位）
	local line_index = build_line_index(tasks)

	return tasks, roots, line_index
end

---------------------------------------------------------------------
-- ⭐ 核心修复：渲染前清除该行所有 extmark，但不读取它们
---------------------------------------------------------------------
--- 渲染单个任务行的视觉元素
--- @param bufnr integer 缓冲区句柄
--- @param task table 任务对象
--- @param line_index table 行号索引（备用，当前未使用）
function M.render_task(bufnr, task, line_index)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local row = math.floor(task.line_num or 1) - 1
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	if row < 0 or row >= line_count then
		return
	end

	local line = get_line(bufnr, row)
	local line_len = #line

	-- 1. 获取任务的权威状态（优先从 store 获取）
	local authoritative_status = nil
	if task.id then
		authoritative_status = get_task_authoritative_status(task.id)
	end
	local is_completed = authoritative_status and types.is_completed_status(authoritative_status) or false

	-- ⭐ 关键修复：清除该行的所有 extmark，但不读取它们
	-- 使用 clear_namespace 清除单行范围
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	-- 2. 删除线（已完成任务）
	if is_completed then
		-- 删除线高亮（覆盖整行）
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
			end_row = row,
			end_col = line_len,
			hl_group = "TodoStrikethrough",
			hl_mode = "combine",
			priority = 200,
		})
		-- 附加完成颜色（可自定义）
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
			end_row = row,
			end_col = line_len,
			hl_group = "TodoCompleted",
			hl_mode = "combine",
			priority = 190,
		})
	end

	-- 3. 构建行尾虚拟文本
	local virt_text_parts = {}

	-- 3.1 子任务进度统计
	if task.children and #task.children > 0 and task.stats then
		local done = task.stats.done or 0
		local total = task.stats.total or #task.children
		if total > 0 then
			if #virt_text_parts > 0 then
				table.insert(virt_text_parts, { " ", "Normal" })
			end
			table.insert(virt_text_parts, {
				string.format("(%d/%d)", math.floor(done), math.floor(total)),
				"Comment",
			})
		end
	end

	-- 3.2 显示链接状态（等待、紧急等）
	local task_id = task.id or extract_task_id_from_line(line)
	if task_id then
		local link_mod = module.get("store.link")
		if link_mod then
			local link = link_mod.get_todo(task_id, { verify_line = true })
			if link then
				-- 使用 status 模块获取显示组件（避免重复逻辑）
				local status_mod = require("todo2.status")
				if status_mod then
					local components = status_mod.get_display_components(link)
					if components and components.icon and components.icon ~= "" then
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { components.icon, components.icon_highlight })
					end
					if components and components.time and components.time ~= "" then
						if #virt_text_parts > 0 then
							table.insert(virt_text_parts, { " ", "Normal" })
						end
						table.insert(virt_text_parts, { components.time, components.time_highlight })
					end
				end
			end
		end
	end

	-- 4. 应用虚拟文本
	if #virt_text_parts > 0 then
		pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, -1, {
			virt_text = virt_text_parts,
			virt_text_pos = "inline",
			hl_mode = "combine",
			right_gravity = true,
			priority = 300,
		})
	end
end

--- 递归渲染任务及其所有子任务
--- @param bufnr integer
--- @param task table
--- @param line_index table
local function render_tree(bufnr, task, line_index)
	M.render_task(bufnr, task, line_index)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child, line_index)
	end
end

---------------------------------------------------------------------
-- 对外渲染接口（统一入口）
---------------------------------------------------------------------
--- 渲染整个缓冲区
--- @param bufnr integer 缓冲区句柄
--- @param opts table 选项
---   - force_refresh: boolean 是否强制刷新解析缓存（默认 false）
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

	-- 1. 获取任务树（智能选择主树/完整树）
	local tasks, roots, line_index = get_tasks_for_render(path, opts.force_refresh)

	-- 2. 如果没有任何任务，清除命名空间并返回
	if not tasks or #tasks == 0 then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		return 0
	end

	-- 3. 计算统计信息（若 core 模块存在，向后兼容）
	local core = module.get("core")
	if core and core.calculate_all_stats then
		core.calculate_all_stats(tasks)
	end

	-- ⭐ 清除当前缓冲区 todo2 命名空间的所有 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- 5. 重新渲染所有根任务
	for _, root in ipairs(roots) do
		render_tree(bufnr, root, line_index)
	end

	return #tasks
end

---------------------------------------------------------------------
-- 缓存管理
---------------------------------------------------------------------
--- 清除所有缓冲区的渲染 extmark，并可选刷新解析缓存
--- @param refresh_parser boolean 是否同时刷新解析缓存（默认 false）
function M.clear_cache(refresh_parser)
	-- 清除所有缓冲区的渲染标记
	local bufnrs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufnrs) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end

	-- 按需刷新解析缓存
	if refresh_parser then
		parser.invalidate_cache()
	end
end

--- 兼容旧接口
M.clear = M.clear_cache

return M
