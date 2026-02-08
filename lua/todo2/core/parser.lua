-- 文件位置：lua/todo2/core/parser.lua
-- 精简版：与存储模块对齐的最小必要修改

local M = {}

---------------------------------------------------------------------
-- 基础依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local cache = require("todo2.cache")
local format = require("todo2.utils.format")
local INDENT_WIDTH = config.get("indent_width") or 2

---------------------------------------------------------------------
-- 只导入必要的存储模块组件
---------------------------------------------------------------------
local store_types = require("todo2.store.types")

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

local function compute_level(indent)
	return math.floor(indent / INDENT_WIDTH)
end

---------------------------------------------------------------------
-- ⭐ 修改点1：增强的parse_task_line，支持状态解析
---------------------------------------------------------------------
local function parse_task_line(line)
	local parsed = format.parse_task_line(line)
	if not parsed then
		return nil
	end

	parsed.level = compute_level(#parsed.indent)

	-- ⭐ 新增：解析状态（最小必要实现）
	if line:match("%[x%]") then
		parsed.status = store_types.STATUS.COMPLETED
	elseif line:match("%[!%]") then
		parsed.status = store_types.STATUS.URGENT
	elseif line:match("%[\\?%]") then
		parsed.status = store_types.STATUS.WAITING
	elseif line:match("%[>%]") then
		parsed.status = store_types.STATUS.ARCHIVED
	else
		parsed.status = store_types.STATUS.NORMAL
	end

	-- ⭐ 新增：确保ID有效
	if parsed.id and not parsed.id:match("^[a-zA-Z0-9_][a-zA-Z0-9_-]*$") then
		-- 简单修复：移除无效字符
		parsed.id = parsed.id:gsub("[^a-zA-Z0-9_-]", "_")
	end

	return parsed
end

---------------------------------------------------------------------
-- ⭐ 核心任务树构建（基本不变，只添加状态支持）
---------------------------------------------------------------------
local function build_task_tree(lines, path)
	local tasks = {}
	local id_to_task = {}
	local stack = {}

	for i, line in ipairs(lines) do
		if format.is_task_line(line) then
			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

				-- 记录id映射
				if task.id then
					id_to_task[task.id] = task
				end

				-- 找父节点
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
-- ⭐ 修改点2：新增数据转换函数（最小必要）
---------------------------------------------------------------------
function M.convert_to_store_format(task, link_type)
	return {
		id = task.id,
		type = link_type or "todo_to_code",
		path = task.path,
		line = task.line_num,
		content = task.content or "",
		tag = task.tag or "TODO",
		status = task.status or store_types.STATUS.NORMAL,
	}
end

function M.convert_from_store_format(store_task)
	return {
		id = store_task.id,
		content = store_task.content,
		tag = store_task.tag,
		level = 0, -- 存储中可能没有，设为0
		line_num = store_task.line,
		path = store_task.path,
		status = store_task.status,
		children = {},
		parent = nil,
		order = 1,
	}
end

---------------------------------------------------------------------
-- 原有API（保持完全兼容）
---------------------------------------------------------------------

-- 解析文件（带缓存）
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
	local tasks, roots, id_to_task = build_task_tree(lines, path)

	cache.cache_parse(path, {
		mtime = mtime,
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
	})

	return tasks, roots, id_to_task
end

-- 根据id获取任务
function M.get_task_by_id(path, id)
	local tasks, roots, id_to_task = M.parse_file(path)
	return id_to_task and id_to_task[id]
end

-- 安全获取任务
function M.get_task_by_id_safe(path, id)
	local task = M.get_task_by_id(path, id)
	if task and task.parent and not M.get_task_by_id(path, task.parent.id) then
		task.parent = nil
	end
	return task
end

-- 清理缓存
function M.invalidate_cache(filepath)
	if filepath then
		filepath = vim.fn.fnamemodify(filepath, ":p")
		cache.clear_file_cache(filepath)
	else
		cache.clear_category("parser")
	end
end

-- 解析内存中的任务行
function M.parse_tasks(lines)
	if not lines or #lines == 0 then
		return {}
	end
	local tasks = build_task_tree(lines, "")
	return tasks
end

---------------------------------------------------------------------
-- ⭐ 修改点3：新增简单状态管理函数
---------------------------------------------------------------------
function M.get_task_status(task)
	return task.status or store_types.STATUS.NORMAL
end

function M.set_task_status(task, status)
	if not task then
		return false
	end
	task.status = status
	return true
end

---------------------------------------------------------------------
-- 工具函数导出（保持兼容）
---------------------------------------------------------------------
function M.parse_task_line(line)
	return parse_task_line(line)
end

function M.is_task_line(line)
	return format.is_task_line(line)
end

function M.compute_level(indent)
	return compute_level(indent)
end

---------------------------------------------------------------------
-- ⭐ 修改点4：新增简单同步函数（可选）
---------------------------------------------------------------------
function M.sync_with_store(filepath)
	-- 最简单的实现：只记录需要同步，让上层处理
	vim.schedule(function()
		vim.notify("解析完成，请调用存储模块进行同步", vim.log.levels.INFO)
	end)
	return true
end

---------------------------------------------------------------------
-- 保持向后兼容的别名
---------------------------------------------------------------------
M.clear_cache = M.invalidate_cache
M.get_indent_width = function()
	return INDENT_WIDTH
end

return M
