-- lua/todo2/core/parser.lua
--- @module todo2.core.parser
--- @brief 专业级任务树解析器（权威结构源）

local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

-- 每多少空格算一级缩进（2 或 4）
local INDENT_WIDTH = 2

-- 缓存：path → { mtime, tasks, roots }
local file_cache = {}

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
-- ⭐ 核心：构建任务树（权威结构）
---------------------------------------------------------------------

local function build_task_tree(lines, path)
	local tasks = {}
	local stack = {}

	for i, line in ipairs(lines) do
		if is_task_line(line) then
			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

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

	return tasks, roots
end

---------------------------------------------------------------------
-- ⭐ 对外 API：解析文件（带缓存）
---------------------------------------------------------------------

function M.parse_file(path, force_refresh)
	path = vim.fn.fnamemodify(path, ":p")

	-- ⭐ 新增 force_refresh 参数
	if force_refresh then
		file_cache[path] = nil
	end

	local mtime = get_file_mtime(path)
	local cached = file_cache[path]

	if cached and cached.mtime == mtime then
		return cached.tasks, cached.roots
	end

	local lines = safe_readfile(path)
	local tasks, roots = build_task_tree(lines, path)

	file_cache[path] = {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
	}

	return tasks, roots
end

function M.clear_cache()
	file_cache = {}
end

return M
