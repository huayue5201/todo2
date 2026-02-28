-- lua/todo2/core/parser.lua
--- @module todo2.core.parser
--- 核心解析器模块

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local store_types = require("todo2.store.types")

---------------------------------------------------------------------
-- LRU 缓存实现
---------------------------------------------------------------------

local function create_lru_cache(max_size)
	local cache = {}
	local access_order = {}

	return {
		get = function(key)
			local item = cache[key]
			if item then
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

		set = function(key, value)
			if cache[key] then
				for i, k in ipairs(access_order) do
					if k == key then
						table.remove(access_order, i)
						break
					end
				end
			end

			if #access_order >= max_size and not cache[key] then
				local oldest_key = access_order[#access_order]
				cache[oldest_key] = nil
				table.remove(access_order)
			end

			cache[key] = { value = value }
			table.insert(access_order, 1, key)
		end,

		delete = function(key)
			cache[key] = nil
			for i, k in ipairs(access_order) do
				if k == key then
					table.remove(access_order, i)
					break
				end
			end
		end,

		clear = function()
			cache = {}
			access_order = {}
		end,

		size = function()
			return #access_order
		end,

		keys = function()
			local keys = {}
			for k, _ in pairs(cache) do
				table.insert(keys, k)
			end
			return keys
		end,
	}
end

local parser_cache = create_lru_cache(50)

---------------------------------------------------------------------
-- 缩进配置
---------------------------------------------------------------------
local INDENT_WIDTH = config.get("indent_width") or 2

local function compute_level(indent)
	local spaces
	if type(indent) == "string" then
		spaces = #indent
	else
		spaces = indent
	end
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
		empty_line_reset = config.get("parser.empty_line_reset") or 2,
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
-- 从缓冲区生成上下文指纹
---------------------------------------------------------------------
function M.generate_context_fingerprint(bufnr, lnum)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local context_module = require("todo2.store.context")
	return context_module.build_from_buffer(bufnr, lnum)
end

---------------------------------------------------------------------
-- 解析任务行
---------------------------------------------------------------------
local function parse_task_line(line, opts)
	opts = opts or {}
	local parsed = format.parse_task_line(line)
	if type(parsed) ~= "table" then
		return nil
	end

	parsed.level = compute_level(parsed.indent)

	if line:match("%[x%]") then
		parsed.status = store_types.STATUS.COMPLETED
	elseif line:match("%[>%]") then
		parsed.status = store_types.STATUS.ARCHIVED
	elseif line:match("%[%s+%]") or line:match("%[%]") then
		parsed.status = store_types.STATUS.NORMAL
	else
		parsed.status = store_types.STATUS.NORMAL
	end

	if parsed.id and not parsed.id:match("^[a-zA-Z0-9_][a-zA-Z0-9_-]*$") then
		parsed.id = parsed.id:gsub("[^a-zA-Z0-9_-]", "_")
	end

	if opts.context_fingerprint then
		parsed.context_fingerprint = opts.context_fingerprint
	end

	parsed.context_lines = {}
	parsed.context_before = {}
	parsed.context_after = {}

	return parsed
end

M.parse_task_line = parse_task_line

---------------------------------------------------------------------
-- 核心任务树构建
---------------------------------------------------------------------
local function build_task_tree_enhanced(lines, path, opts)
	opts = opts or {}
	local use_empty_line_reset = opts.use_empty_line_reset or false
	local empty_line_threshold = opts.empty_line_threshold or 2
	local is_isolated_region = opts.is_isolated_region or false
	local generate_context = opts.generate_context or false

	local tasks = {}
	local id_to_task = {}
	local stack = {}
	local roots = {}

	local consecutive_empty = 0
	local last_context = nil
	local last_task = nil

	local last_valid_region_tasks = {}
	local region_boundary_lines = {}

	if is_isolated_region then
		stack = {}
	end

	local temp_buf = nil
	if generate_context and path then
		temp_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)
	end

	for i, line in ipairs(lines) do
		local indent_str = line:match("^%s*") or ""
		local indent = #indent_str

		if format.is_task_line(line) then
			if use_empty_line_reset and consecutive_empty >= empty_line_threshold then
				if #stack > 0 then
					local region_start = stack[1].line_num
					local region_end = i - 1

					for _, task_in_region in ipairs(stack) do
						task_in_region.region_id = #region_boundary_lines + 1
						task_in_region.region_start = region_start
						task_in_region.region_end = region_end
					end

					table.insert(region_boundary_lines, {
						start = region_start,
						end_line = region_end,
						tasks = vim.deepcopy(stack),
					})
				end

				stack = {}
			end
			consecutive_empty = 0

			local context_fingerprint = nil
			if generate_context and temp_buf then
				local context_module = require("todo2.store.context")
				context_fingerprint = context_module.build_from_buffer(temp_buf, i, path)
			end

			local task = parse_task_line(line, { context_fingerprint = context_fingerprint })
			if not task then
				goto continue
			end

			task.line_num = i
			task.path = path
			task.children = {}
			task.region_id = nil

			local parent = nil
			for j = #stack, 1, -1 do
				if stack[j].level < task.level then
					parent = stack[j]
					break
				end
			end

			if parent then
				task.parent = parent
				table.insert(parent.children, task)
			else
				task.parent = nil
				table.insert(roots, task)
			end

			while #stack > 0 and stack[#stack].level >= task.level do
				table.remove(stack)
			end

			table.insert(stack, task)

			if task.id then
				id_to_task[task.id] = task
			end

			table.insert(tasks, task)
			last_task = task

			if last_context and not last_context.is_empty then
				if last_context.level > task.level then
					last_context.belongs_to = task
					table.insert(task.context_before, last_context)
				end
			end
		else
			local context = ContextLine.new(i, line, indent)

			if context.is_empty then
				consecutive_empty = consecutive_empty + 1
			else
				consecutive_empty = 0
				last_context = context

				if #stack > 0 then
					local current_task = stack[#stack]
					context.belongs_to = current_task
					table.insert(current_task.context_after, context)
				end
			end
		end

		::continue::
	end

	if #stack > 0 then
		local region_start = stack[1].line_num
		local region_end = #lines

		for _, task_in_region in ipairs(stack) do
			task_in_region.region_id = #region_boundary_lines + 1
			task_in_region.region_start = region_start
			task_in_region.region_end = region_end
		end

		table.insert(region_boundary_lines, {
			start = region_start,
			end_line = region_end,
			tasks = vim.deepcopy(stack),
		})
	end

	if temp_buf and vim.api.nvim_buf_is_valid(temp_buf) then
		vim.api.nvim_buf_delete(temp_buf, { force = true })
	end

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
-- ⭐ 修改：归档区域检测
---------------------------------------------------------------------
local function detect_archive_sections(lines, archive_module)
	if archive_module and archive_module.detect_archive_sections then
		return archive_module.detect_archive_sections(lines)
	end

	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		-- ⭐ 使用配置函数检测归档区域标题
		if config.is_archive_section_line(line) then
			if current_section then
				current_section.end_line = i - 1
				table.insert(sections, current_section)
			end
			current_section = {
				start_line = i,
				month = config.extract_month_from_archive_title(line) or "",
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
-- 主任务树解析
---------------------------------------------------------------------
function M.parse_main_tree(path, force_refresh, archive_module)
	local cfg = get_config()
	path = get_absolute_path(path)

	local cache_key = "main:" .. path
	local mtime = get_file_mtime(path)

	if force_refresh then
		parser_cache:delete(cache_key)
	end

	local cached = parser_cache:get(cache_key)
	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	local tasks, roots, id_map

	if #archive_sections == 0 then
		tasks, roots, id_map = build_task_tree_enhanced(lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = false,
			generate_context = true,
		})
	else
		local main_lines = {}
		for i = 1, archive_sections[1].start_line - 1 do
			table.insert(main_lines, lines[i])
		end

		tasks, roots, id_map = build_task_tree_enhanced(main_lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = false,
			generate_context = true,
		})
	end

	parser_cache:set(cache_key, {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_map,
	})

	return tasks, roots, id_map
end

---------------------------------------------------------------------
-- 归档任务树解析
---------------------------------------------------------------------
function M.parse_archive_trees(path, force_refresh, archive_module)
	local cfg = get_config()
	path = get_absolute_path(path)

	local cache_key = "archive:" .. path
	local mtime = get_file_mtime(path)

	if force_refresh then
		parser_cache:delete(cache_key)
	end

	local cached = parser_cache:get(cache_key)
	if cached and cached.mtime == mtime then
		return cached.trees
	end

	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	local trees = {}

	for _, section in ipairs(archive_sections) do
		local section_lines = {}
		for i = section.start_line + 1, section.end_line do
			if lines[i] then
				table.insert(section_lines, lines[i])
			end
		end

		local tasks, roots, id_map = build_task_tree_enhanced(section_lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
			is_isolated_region = true,
			generate_context = false,
		})

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

	parser_cache:set(cache_key, {
		mtime = mtime,
		trees = trees,
	})

	return trees
end

function M.parse_file(path, force_refresh)
	return M.parse_main_tree(path, force_refresh)
end

function M.invalidate_cache(filepath)
	if filepath then
		filepath = get_absolute_path(filepath)
		parser_cache:delete("main:" .. filepath)
		parser_cache:delete("archive:" .. filepath)
	else
		parser_cache:clear()
	end
end

function M.get_cache_stats()
	return {
		size = parser_cache.size(),
		keys = parser_cache.keys(),
		max_size = 50,
	}
end

function M.clear_cache()
	parser_cache:clear()
end

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
