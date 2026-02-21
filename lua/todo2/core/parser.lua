-- lua/todo2/core/parser.lua (缓存策略统一为LRU版)
--- @module todo2.core.parser
--- 核心解析器模块
--- 修复：正确的父子关系构建 + 空行重置 + 独立区域解析

-- TODO:ref:4f0400
local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local format = require("todo2.utils.format")
local store_types = require("todo2.store.types")

---------------------------------------------------------------------
-- ⭐ 新增：LRU 缓存实现（与 autofix.lua 保持一致）
---------------------------------------------------------------------

--- 简单的 LRU 缓存实现
--- @param max_size number 最大缓存项数
--- @return table
local function create_lru_cache(max_size)
	local cache = {}
	local access_order = {}

	return {
		--- 获取缓存项
		--- @param key string
		--- @return any
		get = function(key)
			local item = cache[key]
			if item then
				-- 将刚访问的键移到最前（最近使用）
				for i, k in ipairs(access_order) do
					if k == key then
						table.remove(access_order, i)
						break
					end
				end
				table.insert(access_order, 1, key)
				return item.value
			end
			return nil
		end,

		--- 设置缓存项
		--- @param key string
		--- @param value any
		set = function(key, value)
			-- 如果已存在，先移除旧的访问记录
			if cache[key] then
				for i, k in ipairs(access_order) do
					if k == key then
						table.remove(access_order, i)
						break
					end
				end
			end

			-- 如果达到最大容量，删除最久未使用的项
			if #access_order >= max_size and not cache[key] then
				local oldest_key = access_order[#access_order]
				cache[oldest_key] = nil
				table.remove(access_order)
			end

			-- 存入新值，放到最近使用位置
			cache[key] = { value = value }
			table.insert(access_order, 1, key)
		end,

		--- 删除缓存项
		--- @param key string
		delete = function(key)
			cache[key] = nil
			for i, k in ipairs(access_order) do
				if k == key then
					table.remove(access_order, i)
					break
				end
			end
		end,

		--- 清空缓存
		clear = function()
			cache = {}
			access_order = {}
		end,

		--- 获取缓存大小
		size = function()
			return #access_order
		end,

		--- 获取所有键
		keys = function()
			local keys = {}
			for k, _ in pairs(cache) do
				table.insert(keys, k)
			end
			return keys
		end,
	}
end

-- ⭐ 创建 LRU 缓存实例
local parser_cache = create_lru_cache(50) -- 最多缓存50个文件的解析结果

---------------------------------------------------------------------
-- 缩进配置
---------------------------------------------------------------------
local INDENT_WIDTH = config.get("indent_width") or 2

--- 计算缩进级别
--- @param indent string|number 缩进字符串或空格数
--- @return number 缩进级别
local function compute_level(indent)
	local spaces
	if type(indent) == "string" then
		spaces = #indent
	else
		spaces = indent
	end
	-- 使用四舍五入而不是floor，处理非标准缩进
	return math.floor((spaces + INDENT_WIDTH / 2) / INDENT_WIDTH)
end

---------------------------------------------------------------------
-- 核心工具函数
---------------------------------------------------------------------
local function get_file_mtime(path)
	local stat = vim.loop.fs_stat(path)
	return stat and stat.mtime.sec or 0
end

local function safe_readfile(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or {}
end

local function get_absolute_path(path)
	if not path or path == "" then
		return ""
	end
	path = path:gsub("^~", vim.loop.os_homedir())
	if not path:match("^/") then
		path = vim.loop.fs_realpath(vim.fn.getcwd() .. "/" .. path) or path
	else
		path = vim.loop.fs_realpath(path) or path
	end
	return path
end

---------------------------------------------------------------------
-- 配置访问
---------------------------------------------------------------------
local function get_config()
	return {
		empty_line_reset = config.get("parser.empty_line_reset") or 2, -- 默认2行空行重置
		context_split = config.get("parser.context_split") or false,
	}
end

---------------------------------------------------------------------
-- 上下文行对象
---------------------------------------------------------------------
local ContextLine = {
	new = function(line_num, content, indent)
		return {
			type = "context",
			line_num = line_num,
			content = content,
			indent = indent,
			level = compute_level(indent),
			belongs_to = nil,
			is_empty = content:match("^%s*$") ~= nil,
		}
	end,
}

---------------------------------------------------------------------
-- ⭐ 新增：从缓冲区生成上下文指纹
---------------------------------------------------------------------
--- 从缓冲区生成上下文指纹
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @return table|nil 上下文指纹
function M.generate_context_fingerprint(bufnr, lnum)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local context_module = require("todo2.store.context")
	local ctx = context_module.build_from_buffer(bufnr, lnum)
	return ctx:to_storable()
end

---------------------------------------------------------------------
-- 解析任务行（增强：支持上下文指纹）
---------------------------------------------------------------------
local function parse_task_line(line, opts)
	opts = opts or {}
	local parsed = format.parse_task_line(line)
	if type(parsed) ~= "table" then
		return nil
	end

	-- 计算缩进级别
	parsed.level = compute_level(parsed.indent)

	-- 状态映射
	if line:match("%[x%]") then
		parsed.status = store_types.STATUS.COMPLETED
	elseif line:match("%[>%]") then
		parsed.status = store_types.STATUS.ARCHIVED
	elseif line:match("%[%s+%]") or line:match("%[%]") then
		parsed.status = store_types.STATUS.NORMAL
	else
		parsed.status = store_types.STATUS.NORMAL
	end

	-- 确保ID有效
	if parsed.id and not parsed.id:match("^[a-zA-Z0-9_][a-zA-Z0-9_-]*$") then
		parsed.id = parsed.id:gsub("[^a-zA-Z0-9_-]", "_")
	end

	-- ⭐ 如果提供了上下文指纹，保存
	if opts.context_fingerprint then
		parsed.context_fingerprint = opts.context_fingerprint
	end

	-- 上下文存储
	parsed.context_lines = {}
	parsed.context_before = {}
	parsed.context_after = {}

	return parsed
end

M.parse_task_line = parse_task_line

---------------------------------------------------------------------
-- 核心任务树构建（增强版）
---------------------------------------------------------------------
--- 构建任务树
--- @param lines table 文件行列表
--- @param path string 文件路径
--- @param opts table 选项
--- @return tasks, roots, id_to_task
local function build_task_tree_enhanced(lines, path, opts)
	opts = opts or {}
	local use_empty_line_reset = opts.use_empty_line_reset or false
	local empty_line_threshold = opts.empty_line_threshold or 2
	local is_isolated_region = opts.is_isolated_region or false
	local generate_context = opts.generate_context or false -- ⭐ 是否生成上下文

	local tasks = {}
	local id_to_task = {}
	local stack = {} -- 任务栈，存储当前路径上的任务
	local roots = {} -- 根节点列表

	local consecutive_empty = 0
	local last_context = nil
	local last_task = nil

	-- 如果是隔离区域，清空栈
	if is_isolated_region then
		stack = {}
	end

	-- ⭐ 如果需要生成上下文，创建临时缓冲区
	local temp_buf = nil
	if generate_context and path then
		temp_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)
	end

	for i, line in ipairs(lines) do
		local indent_str = line:match("^%s*") or ""
		local indent = #indent_str

		if format.is_task_line(line) then
			-- 任务行处理

			-- 空行重置检查
			if use_empty_line_reset and consecutive_empty >= empty_line_threshold then
				-- 达到空行阈值，重置整个栈（新列表开始）
				stack = {}
				roots = {} -- 重置根节点列表
			end
			consecutive_empty = 0

			-- ⭐ 生成上下文指纹
			local context_fingerprint = nil
			if generate_context and temp_buf then
				local context_module = require("todo2.store.context")
				local ctx = context_module.build_from_buffer(temp_buf, i)
				context_fingerprint = ctx:to_storable()
			end

			local task = parse_task_line(line, { context_fingerprint = context_fingerprint })
			if not task then
				goto continue
			end

			task.line_num = i
			task.path = path
			task.children = {} -- 确保children字段存在

			-- 查找父节点：从栈顶向下找第一个缩进小于当前任务的节点
			local parent = nil
			for j = #stack, 1, -1 do
				if stack[j].level < task.level then
					parent = stack[j]
					break
				end
			end

			-- 设置父子关系
			if parent then
				task.parent = parent
				table.insert(parent.children, task)
			else
				task.parent = nil
				table.insert(roots, task)
			end

			-- 更新栈：移除所有缩进大于等于当前任务的任务
			while #stack > 0 and stack[#stack].level >= task.level do
				table.remove(stack)
			end

			-- 将当前任务压入栈
			table.insert(stack, task)

			-- 记录ID
			if task.id then
				id_to_task[task.id] = task
			end

			table.insert(tasks, task)
			last_task = task

			-- 关联前面的上下文
			if last_context and not last_context.is_empty then
				-- 只有当上下文的缩进大于任务缩进时，才认为是任务的描述
				if last_context.level > task.level then
					last_context.belongs_to = task
					table.insert(task.context_before, last_context)
				end
			end
		else
			-- 非任务行处理
			local context = ContextLine.new(i, line, indent)

			if context.is_empty then
				consecutive_empty = consecutive_empty + 1
			else
				consecutive_empty = 0
				last_context = context

				-- 将上下文关联到当前任务
				if #stack > 0 then
					local current_task = stack[#stack]
					context.belongs_to = current_task
					table.insert(current_task.context_after, context)
				end
			end
		end

		::continue::
	end

	-- ⭐ 清理临时缓冲区
	if temp_buf and vim.api.nvim_buf_is_valid(temp_buf) then
		vim.api.nvim_buf_delete(temp_buf, { force = true })
	end

	-- 为每个任务整理上下文（按行号排序）
	for _, task in ipairs(tasks) do
		if task.context_before then
			table.sort(task.context_before, function(a, b)
				return a.line_num < b.line_num
			end)
		end
		if task.context_after then
			table.sort(task.context_after, function(a, b)
				return a.line_num < b.line_num
			end)
		end
	end

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- 归档区域检测
---------------------------------------------------------------------
local function detect_archive_sections(lines, archive_module)
	if archive_module and archive_module.detect_archive_sections then
		return archive_module.detect_archive_sections(lines)
	end

	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		-- TODO:ref:b51011
		if line:match("^## Archived %(%d%d%d%d%-%d%d%)") then
			if current_section then
				current_section.end_line = i - 1
				table.insert(sections, current_section)
			end
			current_section = {
				start_line = i,
				month = line:match("%((%d%d%d%d%-%d%d)%)"),
			}
		elseif current_section and line:match("^## ") then
			current_section.end_line = i - 1
			table.insert(sections, current_section)
			current_section = nil
		end
	end

	if current_section then
		current_section.end_line = #lines
		table.insert(sections, current_section)
	end

	return sections
end

---------------------------------------------------------------------
-- ⭐ 修改：主任务树解析（使用 LRU 缓存）
---------------------------------------------------------------------
function M.parse_main_tree(path, force_refresh, archive_module)
	local cfg = get_config()
	path = get_absolute_path(path)

	local cache_key = "main:" .. path
	local mtime = get_file_mtime(path)

	-- 强制刷新时删除缓存
	if force_refresh then
		parser_cache:delete(cache_key)
	end

	-- 从 LRU 缓存获取
	local cached = parser_cache:get(cache_key)
	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	-- 解析文件
	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	local tasks, roots, id_map

	if #archive_sections == 0 then
		-- 没有归档区域，正常解析
		tasks, roots, id_map = build_task_tree_enhanced(lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = false,
			generate_context = true, -- ⭐ 生成上下文指纹
		})
	else
		-- 提取主区域
		local main_lines = {}
		for i = 1, archive_sections[1].start_line - 1 do
			table.insert(main_lines, lines[i])
		end

		tasks, roots, id_map = build_task_tree_enhanced(main_lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = false,
			generate_context = true, -- ⭐ 生成上下文指纹
		})
	end

	-- 存入 LRU 缓存
	parser_cache:set(cache_key, {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_map,
	})

	return tasks, roots, id_map
end

---------------------------------------------------------------------
-- ⭐ 修改：归档任务树解析（使用 LRU 缓存）
---------------------------------------------------------------------
function M.parse_archive_trees(path, force_refresh, archive_module)
	local cfg = get_config()
	path = get_absolute_path(path)

	local cache_key = "archive:" .. path
	local mtime = get_file_mtime(path)

	-- 强制刷新时删除缓存
	if force_refresh then
		parser_cache:delete(cache_key)
	end

	-- 从 LRU 缓存获取
	local cached = parser_cache:get(cache_key)
	if cached and cached.mtime == mtime then
		return cached.trees
	end

	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	local trees = {}

	for _, section in ipairs(archive_sections) do
		-- 提取区域行
		local section_lines = {}
		for i = section.start_line + 1, section.end_line do
			if lines[i] then
				table.insert(section_lines, lines[i])
			end
		end

		-- 作为独立区域解析
		local tasks, roots, id_map = build_task_tree_enhanced(section_lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = true,
			generate_context = false, -- ⭐ 归档区域不生成上下文
		})

		-- 调整行号
		local function adjust_line_numbers(node)
			if node.line_num then
				node.line_num = node.line_num + section.start_line
			end
			if node.children then
				for _, child in ipairs(node.children) do
					adjust_line_numbers(child)
				end
			end
		end

		for _, task in ipairs(tasks) do
			adjust_line_numbers(task)
		end

		trees[section.month] = {
			tasks = tasks,
			roots = roots,
			id_to_task = id_map,
			start_line = section.start_line,
			end_line = section.end_line,
		}
	end

	-- 存入 LRU 缓存
	parser_cache:set(cache_key, {
		mtime = mtime,
		trees = trees,
	})

	return trees
end

---------------------------------------------------------------------
-- 兼容接口
---------------------------------------------------------------------
function M.parse_file(path, force_refresh)
	return M.parse_main_tree(path, force_refresh)
end

---------------------------------------------------------------------
-- ⭐ 修改：缓存失效（适配 LRU）
---------------------------------------------------------------------
function M.invalidate_cache(filepath)
	if filepath then
		filepath = get_absolute_path(filepath)
		parser_cache:delete("main:" .. filepath)
		parser_cache:delete("archive:" .. filepath)
	else
		-- 如果没有指定文件，清空整个缓存
		parser_cache:clear()
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：缓存管理函数
---------------------------------------------------------------------

--- 获取缓存统计
function M.get_cache_stats()
	return {
		size = parser_cache.size(),
		keys = parser_cache.keys(),
		max_size = 50,
	}
end

--- 清空缓存
function M.clear_cache()
	parser_cache:clear()
end

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
function M.get_task_context(task)
	if not task then
		return { before = {}, after = {} }
	end

	return {
		before = task.context_before or {},
		after = task.context_after or {},
		all = vim.list_extend(vim.deepcopy(task.context_before or {}), vim.deepcopy(task.context_after or {})),
	}
end

function M.get_task_descendants(task)
	local descendants = {}

	local function collect(node)
		for _, child in ipairs(node.children or {}) do
			table.insert(descendants, child)
			collect(child)
		end
	end

	collect(task)
	return descendants
end

return M
