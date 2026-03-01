-- lua/todo2/core/parser.lua
--- @module todo2.core.parser
--- 核心解析器模块（修复归档区域独立性问题）

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
-- ⭐ 修复：检测归档区域（使用配置，并返回完整信息）
---------------------------------------------------------------------
local function detect_archive_sections(lines)
	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		-- 使用配置函数检测归档区域标题
		if config.is_archive_section_line(line) then
			-- 结束上一个归档区域
			if current_section then
				current_section.end_line = i - 1
				table.insert(sections, current_section)
			end

			-- 开始新的归档区域
			current_section = {
				type = "archive",
				start_line = i,
				title = line,
				month = config.extract_month_from_archive_title(line) or "",
				end_line = nil, -- 将在后续设置
			}
		elseif current_section and line:match("^## ") and not config.is_archive_section_line(line) then
			-- 遇到其他标题，结束当前归档区域
			current_section.end_line = i - 1
			table.insert(sections, current_section)
			current_section = nil
		end
	end

	-- 处理最后一个归档区域
	if current_section then
		current_section.end_line = #lines
		table.insert(sections, current_section)
	end

	return sections
end

---------------------------------------------------------------------
-- ⭐ 修复：检测主区域内的空行分割区域
---------------------------------------------------------------------
local function detect_main_regions(lines, empty_line_threshold)
	local regions = {}
	local current_region_start = 1
	local consecutive_empty = 0

	for i = 1, #lines do
		local line = lines[i]
		local is_empty = line:match("^%s*$") ~= nil

		if is_empty then
			consecutive_empty = consecutive_empty + 1
		else
			-- 遇到非空行，检查是否需要分割区域
			if consecutive_empty >= empty_line_threshold then
				-- 空行数量达到阈值，结束当前区域
				if current_region_start <= i - consecutive_empty - 1 then
					table.insert(regions, {
						type = "main",
						start_line = current_region_start,
						end_line = i - consecutive_empty - 1,
					})
				end
				current_region_start = i
			end
			consecutive_empty = 0
		end
	end

	-- 处理最后一个区域
	if current_region_start <= #lines then
		table.insert(regions, {
			type = "main",
			start_line = current_region_start,
			end_line = #lines,
		})
	end

	return regions
end

---------------------------------------------------------------------
-- ⭐ 修复：在区域内构建任务树（完全独立，不跨区域）
---------------------------------------------------------------------
local function build_task_tree_in_region(lines, path, region_start, region_type)
	local tasks = {}
	local roots = {}
	local stack = {}
	local id_to_task = {}

	for i, line in ipairs(lines) do
		local global_line_num = i + region_start - 1

		if format.is_task_line(line) then
			local task = parse_task_line(line, {
				context_fingerprint = path .. ":" .. global_line_num,
			})

			if task then
				task.line_num = global_line_num
				task.path = path
				task.children = {}
				task.region_type = region_type

				-- ⭐ 只在当前栈中查找父任务（确保不跨区域）
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

				-- 更新栈
				while #stack > 0 and stack[#stack].level >= task.level do
					table.remove(stack)
				end
				table.insert(stack, task)

				table.insert(tasks, task)

				if task.id then
					id_to_task[task.id] = task
				end
			end
		end
	end

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- ⭐ 修复：主解析函数（完全隔离区域）
---------------------------------------------------------------------
function M.parse_file(path, force_refresh)
	local cfg = get_config()
	path = get_absolute_path(path)

	local cache_key = "file:" .. path
	local mtime = get_file_mtime(path)

	-- 检查缓存
	if not force_refresh then
		local cached = parser_cache:get(cache_key)
		if cached and cached.mtime == mtime then
			return cached.tasks, cached.roots, cached.id_to_task, cached.archive_trees
		end
	end

	-- 读取文件
	local lines = safe_readfile(path)

	-- 检测归档区域
	local archive_sections = detect_archive_sections(lines)

	-- ⭐ 提取主区域内容（排除所有归档区域）
	local main_lines = {}
	local main_line_mapping = {} -- 原始行号到主区域行号的映射
	local in_archive = false
	local current_archive_end = 0

	for i = 1, #lines do
		-- 检查是否进入归档区域
		for _, section in ipairs(archive_sections) do
			if i >= section.start_line and i <= section.end_line then
				in_archive = true
				current_archive_end = section.end_line
				break
			end
		end

		if not in_archive then
			table.insert(main_lines, lines[i])
			main_line_mapping[#main_lines] = i
		end

		-- 如果当前行是归档区域的结束行，退出归档区域
		if in_archive and i == current_archive_end then
			in_archive = false
		end
	end

	-- 检测主区域内的空行分割区域
	local main_regions = detect_main_regions(main_lines, cfg.empty_line_reset)

	-- ⭐ 构建主区域任务（每个区域独立）
	local all_tasks = {}
	local all_roots = {}
	local id_to_task = {}

	for _, region in ipairs(main_regions) do
		-- 提取区域内容
		local region_lines = {}
		for i = region.start_line, region.end_line do
			table.insert(region_lines, main_lines[i])
		end

		-- 独立构建该区域的任务树
		local tasks, roots, id_map =
			build_task_tree_in_region(region_lines, path, main_line_mapping[region.start_line], "main")

		-- 合并结果
		vim.list_extend(all_tasks, tasks)
		vim.list_extend(all_roots, roots)
		for id, task in pairs(id_map) do
			id_to_task[id] = task
		end
	end

	-- ⭐ 构建归档区域任务（每个归档区域独立）
	local archive_trees = {}
	for _, section in ipairs(archive_sections) do
		local section_lines = {}
		for i = section.start_line + 1, section.end_line do
			if lines[i] and not lines[i]:match("^%s*$") then -- 跳过空行
				table.insert(section_lines, lines[i])
			end
		end

		-- 归档区域独立构建（完全隔离）
		local tasks, roots, id_map = build_task_tree_in_region(section_lines, path, section.start_line + 1, "archive")

		archive_trees[section.month or tostring(section.start_line)] = {
			tasks = tasks,
			roots = roots,
			id_to_task = id_map,
			start_line = section.start_line,
			end_line = section.end_line,
			title = section.title,
		}

		-- 归档区域的任务也加入全局ID映射（用于引用）
		for id, task in pairs(id_map) do
			id_to_task[id] = task
		end
	end

	-- 缓存结果
	parser_cache:set(cache_key, {
		mtime = mtime,
		tasks = all_tasks,
		roots = all_roots,
		id_to_task = id_to_task,
		archive_trees = archive_trees,
	})

	return all_tasks, all_roots, id_to_task, archive_trees
end

---------------------------------------------------------------------
-- 兼容原有API
---------------------------------------------------------------------
function M.parse_main_tree(path, force_refresh, archive_module)
	local tasks, roots, id_map = M.parse_file(path, force_refresh)
	return tasks, roots, id_map
end

function M.parse_archive_trees(path, force_refresh, archive_module)
	local _, _, _, archive_trees = M.parse_file(path, force_refresh)
	return archive_trees or {}
end

function M.invalidate_cache(filepath)
	if filepath then
		filepath = get_absolute_path(filepath)
		parser_cache:delete("file:" .. filepath)
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
