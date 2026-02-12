-- lua/todo2/core/parser.lua
--- @module todo2.core.parser
--- 核心解析器模块
--- 增强：空行重置父子关系 + 归档区域独立上下文

local M = {}

---------------------------------------------------------------------
-- 基础依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local cache = require("todo2.cache")
local format = require("todo2.utils.format")
local store_types = require("todo2.store.types") -- ✅ 必须导入
local module = require("todo2.module") -- 延迟加载 archive 模块

---------------------------------------------------------------------
-- 缩进配置
---------------------------------------------------------------------
local INDENT_WIDTH = config.get("indent_width") or 2
local function compute_level(indent)
	return math.floor(indent / INDENT_WIDTH)
end

---------------------------------------------------------------------
-- 核心工具函数（保持不变）
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
-- 配置访问（带默认值）
---------------------------------------------------------------------
local function get_config()
	return {
		empty_line_reset = config.get("parser.empty_line_reset") or 0,
		context_split = config.get("parser.context_split") or false,
	}
end

---------------------------------------------------------------------
-- 延迟加载 archive 模块
---------------------------------------------------------------------
local archive_mod = nil
local function get_archive_module()
	if not archive_mod then
		archive_mod = module.get("todo2.core.archive")
	end
	return archive_mod
end

---------------------------------------------------------------------
-- ✅ 解析任务行（必须返回表或 nil）
---------------------------------------------------------------------
local function parse_task_line(line)
	local parsed = format.parse_task_line(line)
	if type(parsed) ~= "table" then
		return nil
	end

	-- 计算缩进级别
	parsed.level = compute_level(#parsed.indent)

	-- 状态映射（完全兼容原逻辑）
	if line:match("%[x%]") then
		parsed.status = store_types.STATUS.COMPLETED
	elseif line:match("%[!%]") then
		parsed.status = store_types.STATUS.URGENT
	elseif line:match("%[%?%]") then
		parsed.status = store_types.STATUS.WAITING
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

	return parsed
end

---------------------------------------------------------------------
-- 核心任务树构建（支持空行重置）
---------------------------------------------------------------------
--- 构建任务树
--- @param lines table 文件行列表
--- @param path string 文件路径
--- @param opts table 选项
---   - use_empty_line_reset: boolean 是否启用空行重置
---   - empty_line_threshold: number 连续空行阈值（0=禁用）
--- @return tasks, roots, id_to_task
local function build_task_tree(lines, path, opts)
	opts = opts or {}
	local use_empty_line_reset = opts.use_empty_line_reset or false
	local empty_line_threshold = opts.empty_line_threshold or 0

	local tasks = {}
	local id_to_task = {}
	local stack = {}

	local consecutive_empty = 0 -- 连续空行计数器

	for i, line in ipairs(lines) do
		if format.is_task_line(line) then
			-- 任务行：空行重置检测
			if use_empty_line_reset and empty_line_threshold > 0 then
				if consecutive_empty >= empty_line_threshold then
					stack = {} -- 清空栈，后续任务从根开始
				end
				consecutive_empty = 0 -- 重置计数器
			end

			-- ✅ 修复：调用 parse_task_line，而不是 is_task_line
			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

				-- 记录id映射
				if task.id then
					id_to_task[task.id] = task
				end

				-- 找父节点（基于缩进）
				while #stack > 0 and stack[#stack].level >= task.level do
					table.remove(stack)
				end

				if #stack > 0 then
					local parent = stack[#stack]
					task.parent = parent
					table.insert(parent.children, task)
				else
					task.parent = nil
				end

				table.insert(tasks, task)
				table.insert(stack, task)
			end
		else
			-- 非任务行：空行计数器维护
			if use_empty_line_reset then
				if line:match("^%s*$") then
					consecutive_empty = consecutive_empty + 1
				else
					consecutive_empty = 0
				end
			end
		end
	end

	-- 收集根节点
	local roots = {}
	for _, t in ipairs(tasks) do
		if not t.parent then
			table.insert(roots, t)
		end
	end

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- 归档区域检测（复用 archive 模块）
---------------------------------------------------------------------
--- 检测文件中的归档区域边界
--- @param lines table 文件行列表
--- @return table 归档区域列表，每项 {start_line, end_line, month}
local function detect_archive_sections(lines)
	local archive = get_archive_module()
	if archive and archive.detect_archive_sections then
		return archive.detect_archive_sections(lines)
	end
	return {}
end

---------------------------------------------------------------------
-- 主任务树（过滤归档任务）
---------------------------------------------------------------------
--- 获取主任务树（不含任何归档任务）
--- @param path string 文件路径
--- @param force_refresh boolean 强制刷新缓存
--- @return tasks, roots, id_to_task
function M.parse_main_tree(path, force_refresh)
	local cfg = get_config()
	if not cfg.context_split then
		-- 未启用隔离：退化为 parse_file
		return M.parse_file(path, force_refresh)
	end

	path = vim.fn.fnamemodify(path, ":p")

	-- 尝试从缓存获取主树
	if force_refresh then
		cache.delete("parser", cache.KEYS.PARSER_MAIN .. path)
	end

	local mtime = get_file_mtime(path)
	local cached = cache.get_cached_parse(path .. ":main") -- 独立缓存键

	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	-- 读取文件并检测归档区域
	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines)

	-- 如果没有归档区域，主树就是完整树（但也要考虑空行重置）
	if #archive_sections == 0 then
		local tasks, roots, id_map = build_task_tree(lines, path, {
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

	-- 提取主区域行（第一个归档区域之前）
	local main_lines = {}
	for i = 1, archive_sections[1].start_line - 1 do
		table.insert(main_lines, lines[i])
	end

	-- 单独解析主区域（独立栈，支持空行重置）
	local tasks, roots, id_map = build_task_tree(main_lines, path, {
		use_empty_line_reset = cfg.empty_line_reset > 0,
		empty_line_threshold = cfg.empty_line_reset,
	})

	-- 缓存结果
	cache.cache_parse(path .. ":main", {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_map,
	})

	return tasks, roots, id_map
end

---------------------------------------------------------------------
-- 归档任务树（每个归档区域独立解析）
---------------------------------------------------------------------
--- 获取所有归档区域的任务树
--- @param path string 文件路径
--- @param force_refresh boolean 强制刷新缓存
--- @return table 月份 -> { tasks, roots, id_to_task }
function M.parse_archive_trees(path, force_refresh)
	local cfg = get_config()
	if not cfg.context_split then
		return {} -- 未启用隔离，无归档树
	end

	path = vim.fn.fnamemodify(path, ":p")

	-- 缓存键（归档树整体缓存）
	local cache_key = path .. ":archives"
	if force_refresh then
		cache.delete("parser", cache_key)
	end

	local mtime = get_file_mtime(path)
	local cached = cache.get_cached_parse(cache_key)

	if cached and cached.mtime == mtime then
		return cached.trees
	end

	-- 读取文件并检测归档区域
	local lines = safe_readfile(path)
	local archive_sections = detect_archive_sections(lines)

	local trees = {}

	for _, section in ipairs(archive_sections) do
		-- 提取该归档区域的行
		local section_lines = {}
		for i = section.start_line, section.end_line do
			table.insert(section_lines, lines[i])
		end

		-- 独立解析该区域（空行重置独立生效）
		local tasks, roots, id_map = build_task_tree(section_lines, path, {
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

	-- 缓存
	cache.cache_parse(cache_key, {
		mtime = mtime,
		trees = trees,
	})

	return trees
end

---------------------------------------------------------------------
-- 原 parse_file 保持不变（完整树，始终返回所有任务）
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
	-- 完整解析：不使用空行重置（保持原行为）
	local tasks, roots, id_to_task = build_task_tree(lines, path, {
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
-- 兼容旧API（基于完整树）
---------------------------------------------------------------------
function M.get_task_by_id(path, id)
	local tasks, roots, id_to_task = M.parse_file(path)
	return id_to_task and id_to_task[id]
end

function M.invalidate_cache(filepath)
	if filepath then
		filepath = vim.fn.fnamemodify(filepath, ":p")
		cache.clear_file_cache(filepath)
		-- 同时清除主树和归档树缓存
		cache.delete("parser", filepath .. ":main")
		cache.delete("parser", filepath .. ":archives")
	else
		cache.clear_category("parser")
	end
end

return M
