-- lua/todo2/core/parser.lua
-- 修改后的完整文件

local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

-- ⭐ 从配置模块获取缩进宽度
local config = require("todo2.config")
-- 修改点：使用新的配置访问方式
local INDENT_WIDTH = config.get("indent_width") or 2

-- ⭐ 统一缓存管理器
local cache = require("todo2.cache")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function get_file_mtime(path)
	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.mtime then
		return 0
	end
	return stat.mtime.sec
end

local function safe_readfile(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	return lines
end

local function get_indent(line)
	local indent = line:match("^(%s*)")
	return indent and #indent or 0
end

local function compute_level(indent)
	return math.floor(indent / INDENT_WIDTH)
end

local function extract_id(content)
	return content:match("{#(%w+)}")
end

local function clean_content(content)
	content = content:gsub("{#%w+}", "")
	content = vim.trim(content)
	return content
end

local function is_task_line(line)
	return line:match("^%s*[-*+]%s+%[[ xX]%]")
end

local function parse_task_line(line)
	local indent = get_indent(line)
	local level = compute_level(indent)

	local status, content = line:match("^%s*[-*+]%s+(%[[ xX]%])%s*(.*)$")
	if not status then
		return nil
	end

	local id = extract_id(content)
	content = clean_content(content)

	return {
		id = id,
		indent = indent,
		level = level,
		status = status,
		is_done = status == "[x]" or status == "[X]",
		is_todo = status == "[ ]",
		content = content,
		children = {},
		parent = nil,
	}
end

---------------------------------------------------------------------
-- ⭐ 核心：构建任务树（权威结构源） - 添加 id_to_task
---------------------------------------------------------------------

local function build_task_tree(lines, path)
	local tasks = {}
	local id_to_task = {} -- ⭐ 新增：id 到任务的映射
	local stack = {}

	for i, line in ipairs(lines) do
		if is_task_line(line) then
			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

				-- ⭐ 记录 id 到任务的映射
				if task.id then
					id_to_task[task.id] = task
				end

				-- 找父节点（严格按 level）
				while #stack > 0 and stack[#stack].level >= task.level do
					table.remove(stack)
				end

				if #stack > 0 then
					task.parent = stack[#stack]
					table.insert(stack[#stack].children, task)
				end

				table.insert(tasks, task)
				table.insert(stack, task)
			end
		end
	end

	-- 写入 order
	for _, t in ipairs(tasks) do
		if t.parent then
			for idx, child in ipairs(t.parent.children) do
				if child == t then
					t.order = idx
					break
				end
			end
		else
			t.order = 1
		end
	end

	-- 收集根节点
	local roots = {}
	for _, t in ipairs(tasks) do
		if not t.parent then
			table.insert(roots, t)
		end
	end

	return tasks, roots, id_to_task -- ⭐ 返回三个值
end

---------------------------------------------------------------------
-- ⭐ 增强对外 API
---------------------------------------------------------------------

-- ⭐ 解析文件（带缓存） - 现在返回三个值
function M.parse_file(path, force_refresh)
	path = vim.fn.fnamemodify(path, ":p")

	-- 强制刷新时清除缓存
	if force_refresh then
		-- ⭐ 修复：使用 cache.KEYS 而不是 M.KEYS
		local parser_key = cache.KEYS.PARSER_FILE .. path
		cache.delete("parser", parser_key)
	end

	local mtime = get_file_mtime(path)

	-- 检查缓存
	local cached = cache.get_cached_parse(path)
	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	local lines = safe_readfile(path)
	local tasks, roots, id_to_task = build_task_tree(lines, path)

	-- 缓存结果
	cache.cache_parse(path, {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
	})

	return tasks, roots, id_to_task
end

-- ⭐ 新增：根据 id 获取任务
function M.get_task_by_id(path, id)
	local tasks, roots, id_to_task = M.parse_file(path)
	return id_to_task and id_to_task[id]
end

-- ⭐ 新增：清理缓存
function M.invalidate_cache(filepath)
	if filepath then
		filepath = vim.fn.fnamemodify(filepath, ":p")
		cache.clear_file_cache(filepath)
	else
		cache.clear_category("parser")
	end
end

-- ⭐ 新增：获取缓存的文件列表
function M.get_cached_files()
	local files = {}
	-- 注意：这个函数可能不太准确，因为我们不直接暴露缓存的键
	-- 如果需要，可以实现遍历缓存
	return files
end

-- ⭐ 新增：更新缩进宽度配置（在配置变更时调用）
function M.update_indent_width()
	-- 重新从配置获取缩进宽度
	-- 修改点：使用新的配置访问方式
	local new_width = config.get("indent_width")
	if new_width ~= INDENT_WIDTH then
		INDENT_WIDTH = new_width
		-- 清空缓存，因为缩进宽度变了，解析结果会不同
		M.invalidate_cache()
		vim.notify(
			string.format("todo2: 缩进宽度已更新为 %d，缓存已清除", INDENT_WIDTH),
			vim.log.levels.INFO
		)
	end
end

-- ⭐ 获取当前使用的缩进宽度
function M.get_indent_width()
	return INDENT_WIDTH
end

-- ⭐ 保持向后兼容的旧接口
function M.clear_cache()
	cache.clear_category("parser")
end

-- ⭐ 导出工具函数（用于其他模块）
M.get_indent = get_indent
M.is_task_line = is_task_line
M.parse_task_line = parse_task_line
M.compute_level = compute_level

---------------------------------------------------------------------
-- ⭐ 新增公共API：解析内存中的任务行
---------------------------------------------------------------------

-- 解析内存中的任务行（不依赖文件）
function M.parse_tasks(lines)
	if not lines or #lines == 0 then
		return {}
	end

	-- 直接重用现有的 build_task_tree 逻辑
	local tasks, roots, id_to_task = build_task_tree(lines, "")
	return tasks
end

-- 解析单行任务（已有，但明确导出）
function M.parse_task_line(line)
	return parse_task_line(line)
end

-- 计算缩进级别（已有，但明确导出）
function M.compute_level(indent)
	return compute_level(indent)
end

-- 判断是否为任务行（已有，但明确导出）
function M.is_task_line(line)
	return is_task_line(line)
end

return M
