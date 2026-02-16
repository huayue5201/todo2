-- lua/todo2/core/parser.lua
--- @module todo2.core.parser
--- 核心解析器模块
--- 增强：空行重置父子关系 + 归档区域独立上下文 + 智能父子关系

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local cache = require("todo2.cache")
local format = require("todo2.utils.format")
local store_types = require("todo2.store.types")

---------------------------------------------------------------------
-- 缩进配置
---------------------------------------------------------------------
local INDENT_WIDTH = config.get("indent_width") or 2
local function compute_level(indent)
	return math.floor(indent / INDENT_WIDTH)
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

---------------------------------------------------------------------
-- 配置访问
---------------------------------------------------------------------
local function get_config()
	return {
		empty_line_reset = config.get("parser.empty_line_reset") or 0,
		context_split = config.get("parser.context_split") or false,
	}
end

---------------------------------------------------------------------
-- 上下文行对象
---------------------------------------------------------------------
local ContextLine = {
	--- 创建上下文行
	--- @param line_num number 行号
	--- @param content string 内容
	--- @param indent number 缩进空格数
	--- @return table 上下文行对象
	new = function(line_num, content, indent)
		return {
			type = "context",
			line_num = line_num,
			content = content,
			indent = indent,
			level = compute_level(indent),
			belongs_to = nil, -- 属于哪个任务
			is_empty = content:match("^%s*$") ~= nil,
		}
	end,
}

---------------------------------------------------------------------
-- 解析任务行
---------------------------------------------------------------------
local function parse_task_line(line)
	local parsed = format.parse_task_line(line)
	if type(parsed) ~= "table" then
		return nil
	end

	-- 计算缩进级别
	parsed.level = compute_level(#parsed.indent)

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

	-- 增强：添加上下文存储
	parsed.context_lines = {} -- 关联的上下文行
	parsed.context_before = {} -- 前面的上下文
	parsed.context_after = {} -- 后面的上下文

	return parsed
end

M.parse_task_line = parse_task_line

---------------------------------------------------------------------
-- 智能父节点查找
---------------------------------------------------------------------
--- 查找最合适的父节点
--- @param task table 当前任务
--- @param stack table 任务栈
--- @param recent_context table|nil 最近的上下文行
--- @return table|nil 父节点
local function find_parent_intelligent(task, stack, recent_context)
	-- 1. 先按缩进找候选父节点
	local candidate = nil
	for i = #stack, 1, -1 do
		if stack[i].level < task.level then
			candidate = stack[i]
			break
		end
	end

	-- 2. 如果没有候选，说明可能是根节点
	if not candidate then
		return nil
	end

	-- 3. 如果有最近的上下文行，检查列表是否连续
	if recent_context and not recent_context.is_empty then
		-- 如果上下文行的缩进小于等于任务缩进，说明可能开始了新列表
		if recent_context.level <= task.level then
			-- 进一步检查：如果上下文行是普通文本，且缩进很小，很可能是新段落
			if recent_context.level < 2 then -- 缩进小于2个空格
				return nil -- 新列表开始
			end
		end
	end

	return candidate
end

---------------------------------------------------------------------
-- 检查列表是否连续
---------------------------------------------------------------------
--- 判断当前任务是否与之前的任务在同一个列表中
--- @param lines table 所有行
--- @param current_idx number 当前行号
--- @param last_task table 最后一个任务
--- @return boolean 是否连续
local function is_list_continuous(lines, current_idx, last_task)
	if not last_task then
		return true
	end

	-- 向前查找直到找到上一个任务或明显的列表中断标记
	for i = current_idx - 1, last_task.line_num, -1 do
		local line = lines[i]
		if not line:match("^%s*$") then -- 非空行
			-- 检查是否是标题（明显的列表中断）
			if line:match("^#+ ") or line:match("^---+") then
				return false
			end

			-- 检查缩进是否小于最后一个任务的缩进
			local indent = #(line:match("^%s*") or "")
			if indent < last_task.level * INDENT_WIDTH then
				return false
			end
			break
		end
	end

	return true
end

---------------------------------------------------------------------
-- 核心任务树构建（完全修复版）
---------------------------------------------------------------------
--- 构建任务树（修复父子关系和同级任务处理）
--- @param lines table 文件行列表
--- @param path string 文件路径
--- @param opts table 选项
--- @return tasks, roots, id_to_task, contexts
local function build_task_tree_enhanced(lines, path, opts)
	opts = opts or {}
	local use_empty_line_reset = opts.use_empty_line_reset or false
	local empty_line_threshold = opts.empty_line_threshold or 0

	local tasks = {}
	local contexts = {} -- 存储所有上下文行
	local id_to_task = {}
	local stack = {} -- 任务栈，存储当前路径上的任务
	local last_task = nil -- 最后一个任务

	local consecutive_empty = 0
	local last_context = nil -- 最后一个非空上下文行

	for i, line in ipairs(lines) do
		local indent = #(line:match("^%s*") or "")

		if format.is_task_line(line) then
			-- 任务行处理
			if use_empty_line_reset and empty_line_threshold > 0 then
				if consecutive_empty >= empty_line_threshold then
					-- 空行达到阈值，重置栈（新列表开始）
					stack = {}
				end
				consecutive_empty = 0
			end

			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

				-- === 完全修复：正确的父子关系和同级任务处理 ===
				-- 1. 弹出所有缩进大于当前任务的任务（这些是更深层级的子任务）
				while #stack > 0 and stack[#stack].level > task.level do
					table.remove(stack)
				end

				-- 2. 如果栈顶缩进等于当前任务，说明是兄弟关系，也需要弹出（结束上一个同级任务）
				if #stack > 0 and stack[#stack].level == task.level then
					table.remove(stack)
				end

				-- 3. 此时栈顶（如果有）就是父节点
				if #stack > 0 then
					local parent = stack[#stack]
					task.parent = parent
					parent.children = parent.children or {}
					table.insert(parent.children, task)
				else
					task.parent = nil
				end

				-- 4. 将当前任务压入栈
				table.insert(stack, task)

				-- 记录ID
				if task.id then
					id_to_task[task.id] = task
				end

				table.insert(tasks, task)
				last_task = task

				-- 关联上下文行（如果有）
				if last_context and not last_context.is_empty then
					if last_context.level > task.level then
						last_context.belongs_to = task
						task.context_before = task.context_before or {}
						table.insert(task.context_before, last_context)
					end
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

				-- 将上下文关联到当前栈顶的任务
				if #stack > 0 then
					local current_task = stack[#stack]
					context.belongs_to = current_task
					current_task.context_after = current_task.context_after or {}
					table.insert(current_task.context_after, context)
				end
			end

			table.insert(contexts, context)
		end
	end

	-- 收集根节点
	local roots = {}
	for _, t in ipairs(tasks) do
		if not t.parent then
			table.insert(roots, t)
		end
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

	return tasks, roots, id_to_task, contexts
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
-- 主任务树（使用增强解析）
---------------------------------------------------------------------
function M.parse_main_tree(path, force_refresh, archive_module)
	local cfg = get_config()
	if not cfg.context_split then
		return M.parse_file(path, force_refresh)
	end

	path = vim.fn.fnamodify(path, ":p")

	if force_refresh then
		cache.delete("parser", cache.KEYS.PARSER_MAIN .. path)
	end

	local mtime = get_file_mtime(path)
	local cached = cache.get_cached_parse(path .. ":main")

	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	if #archive_sections == 0 then
		-- 使用增强解析
		local tasks, roots, id_map, contexts = build_task_tree_enhanced(lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
		})
		cache.cache_parse(path .. ":main", {
			mtime = mtime,
			tasks = tasks,
			roots = roots,
			id_to_task = id_map,
		})
		return tasks, roots, id_map
	end

	-- 提取主区域
	local main_lines = {}
	for i = 1, archive_sections[1].start_line - 1 do
		table.insert(main_lines, lines[i])
	end

	-- 增强解析主区域
	local tasks, roots, id_map, contexts = build_task_tree_enhanced(main_lines, path, {
		use_empty_line_reset = cfg.empty_line_reset > 0,
		empty_line_threshold = cfg.empty_line_reset,
	})

	cache.cache_parse(path .. ":main", {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_map,
	})

	return tasks, roots, id_map
end

---------------------------------------------------------------------
-- 归档任务树
---------------------------------------------------------------------
function M.parse_archive_trees(path, force_refresh, archive_module)
	local cfg = get_config()
	if not cfg.context_split then
		return {}
	end

	path = vim.fn.fnamemodify(path, ":p")

	local cache_key = path .. ":archives"
	if force_refresh then
		cache.delete("parser", cache_key)
	end

	local mtime = get_file_mtime(path)
	local cached = cache.get_cached_parse(cache_key)

	if cached and cached.mtime == mtime then
		return cached.trees
	end

	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines, archive_module)

	local trees = {}

	for _, section in ipairs(archive_sections) do
		local section_lines = {}
		for i = section.start_line, section.end_line do
			table.insert(section_lines, lines[i])
		end

		-- 归档区域也使用增强解析
		local tasks, roots, id_map, contexts = build_task_tree_enhanced(section_lines, path, {
			use_empty_line_reset = cfg.empty_line_reset > 0,
			empty_line_threshold = cfg.empty_line_reset,
		})

		trees[section.month] = {
			tasks = tasks,
			roots = roots,
			id_to_task = id_map,
			start_line = section.start_line,
			end_line = section.end_line,
		}
	end

	cache.cache_parse(cache_key, {
		mtime = mtime,
		trees = trees,
	})

	return trees
end

---------------------------------------------------------------------
-- 原 parse_file 保持兼容（也使用增强解析）
---------------------------------------------------------------------
function M.parse_file(path, force_refresh)
	path = vim.fn.fnamemodify(path, ":p")

	if force_refresh then
		cache.delete("parser", cache.KEYS.PARSER_FILE .. path)
	end

	local mtime = get_file_mtime(path)
	local cached = cache.get_cached_parse(path)

	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	local lines = safe_readfile(path)
	-- 使用增强解析
	local tasks, roots, id_to_task, contexts = build_task_tree_enhanced(lines, path, {
		use_empty_line_reset = false,
		empty_line_threshold = 0,
	})

	cache.cache_parse(path, {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
	})

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- 新增：获取任务的完整上下文
---------------------------------------------------------------------
--- 获取任务相关的所有上下文行
--- @param task table 任务对象
--- @return table 上下文信息
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

---------------------------------------------------------------------
-- 新增：查找任务的所有后代
---------------------------------------------------------------------
--- 递归获取任务的所有子任务
--- @param task table 任务对象
--- @return table 后代任务列表
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

---------------------------------------------------------------------
-- 缓存失效
---------------------------------------------------------------------
function M.invalidate_cache(filepath)
	if filepath then
		filepath = vim.fn.fnamemodify(filepath, ":p")
		-- ⭐ 修复：使用正确的缓存键格式
		local parser_key = cache.KEYS.PARSER_FILE .. filepath
		cache.delete("parser", parser_key)
		cache.delete("parser", filepath .. ":main")
		cache.delete("parser", filepath .. ":archives")
	else
		cache.clear_category("parser")
	end
end

return M
