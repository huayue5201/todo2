-- 文件位置：lua/todo2/core/parser.lua
-- 增强健壮性的解析模块

local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

-- 从配置模块获取缩进宽度
local config = require("todo2.config")
local INDENT_WIDTH = config.get("indent_width") or 2

-- 统一缓存管理器
local cache = require("todo2.cache")

-- ⭐⭐ 修改点1：导入统一的格式模块
local format = require("todo2.utils.format")

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

---------------------------------------------------------------------
-- ⭐⭐ 修改点2：重写 parse_task_line 函数，使用 format.parse_task_line
---------------------------------------------------------------------
local function parse_task_line(line)
	-- 使用统一的格式模块解析
	local parsed = format.parse_task_line(line)
	if not parsed then
		return nil
	end

	-- 计算缩进级别（使用本地函数）
	parsed.level = compute_level(#parsed.indent)

	return parsed
end

---------------------------------------------------------------------
-- ⭐⭐ 核心：增强健壮性的任务树构建（这个函数基本保持不变，但使用新的 parse_task_line）
---------------------------------------------------------------------

local function build_task_tree(lines, path)
	local tasks = {}
	local id_to_task = {}
	local stack = {}

	for i, line in ipairs(lines) do
		-- ⭐⭐ 修改点3：使用 format.is_task_line 代替原来的 is_task_line
		if format.is_task_line(line) then
			local task = parse_task_line(line)
			if task then
				task.line_num = i
				task.path = path

				-- 记录 id 到任务的映射
				if task.id then
					-- ⭐ 修复：验证ID格式
					if not task.id:match("^[a-zA-Z0-9]+$") then
						local utils = require("todo2.link.utils")
						task.id = utils.generate_id()
					end
					id_to_task[task.id] = task
				end

				-- 找父节点（严格按 level）
				while #stack > 0 and stack[#stack].level >= task.level do
					table.remove(stack)
				end

				-- ⭐ 修复：确保父节点仍然在stack中且有效
				if #stack > 0 then
					local parent = stack[#stack]

					-- 验证父任务是否仍然在文件行中
					if parent and parent.line_num and parent.line_num <= #lines then
						local parent_line = lines[parent.line_num]
						if parent_line and format.is_task_line(parent_line) then
							task.parent = parent
							table.insert(parent.children, task)
						else
							-- 父任务在文件中已不存在，重置为根任务
							task.parent = nil
						end
					else
						task.parent = nil
					end
				else
					task.parent = nil
				end

				table.insert(tasks, task)
				table.insert(stack, task)
			end
		end
	end

	-- ⭐ 关键修复：二次清理无效的父引用
	for _, task in ipairs(tasks) do
		if task.parent then
			-- 检查父任务是否在tasks列表中
			local found = false
			for _, t in ipairs(tasks) do
				if t == task.parent then
					found = true
					break
				end
			end
			if not found then
				task.parent = nil
			end
		end
	end

	-- 写入 order（修正后的父引用）
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

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- ⭐⭐ 增强对外 API（这部分保持不变，但内部已经使用统一的format模块）
---------------------------------------------------------------------

-- 解析文件（带缓存）
function M.parse_file(path, force_refresh)
	path = vim.fn.fnamemodify(path, ":p")

	-- 强制刷新时清除缓存
	if force_refresh then
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

	-- ⭐ 修复：验证并修复任务树的完整性
	local repaired_tasks, repaired_id_to_task = M.validate_and_repair_tasks(tasks, id_to_task)

	-- 缓存修复后的结果
	cache.cache_parse(path, {
		mtime = mtime,
		tasks = repaired_tasks,
		roots = roots,
		id_to_task = repaired_id_to_task,
	})

	return repaired_tasks, roots, repaired_id_to_task
end

-- 根据 id 获取任务
function M.get_task_by_id(path, id)
	local tasks, roots, id_to_task = M.parse_file(path)
	return id_to_task and id_to_task[id]
end

-- ⭐ 新增：安全地根据ID获取任务（带自动修复）
function M.get_task_by_id_safe(path, id)
	local tasks, roots, id_to_task = M.parse_file(path)

	if not id_to_task or not id_to_task[id] then
		return nil
	end

	local task = id_to_task[id]

	-- 验证任务的父引用是否有效
	if task.parent and not id_to_task[task.parent.id] then
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

-- 更新缩进宽度配置（在配置变更时调用）
function M.update_indent_width()
	-- 重新从配置获取缩进宽度
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

-- 获取当前使用的缩进宽度
function M.get_indent_width()
	return INDENT_WIDTH
end

-- 保持向后兼容的旧接口
function M.clear_cache()
	cache.clear_category("parser")
end

-- ⭐ 新增：验证并修复任务树的完整性
function M.validate_and_repair_tasks(tasks, id_to_task)
	if not tasks or #tasks == 0 then
		return {}, {}
	end

	-- 复制一份任务，避免修改原数据
	local repaired_tasks = {}
	local repaired_id_to_task = {}

	for _, task in ipairs(tasks) do
		-- 深度复制任务
		local repaired = vim.deepcopy(task)
		repaired.children = {}
		repaired.parent = nil

		repaired_tasks[#repaired_tasks + 1] = repaired
		if repaired.id then
			repaired_id_to_task[repaired.id] = repaired
		end
	end

	-- 重新建立父子关系
	for i, task in ipairs(repaired_tasks) do
		-- 查找父任务（基于缩进级别）
		local parent_candidate = nil

		for j = i - 1, 1, -1 do
			local candidate = repaired_tasks[j]
			if candidate.level < task.level then
				parent_candidate = candidate
				break
			end
		end

		-- 验证父任务是否仍然存在
		if parent_candidate then
			-- 检查父任务是否在修复后的映射中
			if repaired_id_to_task[parent_candidate.id] then
				task.parent = parent_candidate
				table.insert(parent_candidate.children, task)
			end
		end
	end

	return repaired_tasks, repaired_id_to_task
end

-- 获取缓存的文件列表
function M.get_cached_files()
	local files = {}
	return files
end

-- ⭐⭐ 修改点4：导出工具函数，但改为使用 format 模块
M.get_indent = get_indent
M.is_task_line = format.is_task_line -- 使用 format 模块的 is_task_line
M.parse_task_line = parse_task_line -- 使用本地函数（内部调用 format.parse_task_line）
M.compute_level = compute_level

---------------------------------------------------------------------
-- 新增公共API：解析内存中的任务行
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

-- ⭐⭐ 修改点5：明确导出 parse_task_line 函数
function M.parse_task_line(line)
	return parse_task_line(line)
end

-- ⭐⭐ 修改点6：明确导出 compute_level 函数
function M.compute_level(indent)
	return compute_level(indent)
end

-- ⭐⭐ 修改点7：明确导出 is_task_line 函数（使用 format 模块）
function M.is_task_line(line)
	return format.is_task_line(line)
end

---------------------------------------------------------------------
-- ⭐ 新增：监控和修复任务结构
---------------------------------------------------------------------

--- 监控和修复任务结构
--- @param bufnr number 缓冲区编号
--- @param filepath string 文件路径
function M.monitor_and_repair_tasks(bufnr, filepath)
	-- 清除缓存
	M.invalidate_cache(filepath)

	-- 重新解析文件
	local tasks, roots, id_to_task = M.parse_file(filepath, true)

	-- 验证并修复
	local repaired_tasks, repaired_id_to_task = M.validate_and_repair_tasks(tasks, id_to_task)

	-- 重新缓存修复后的数据
	local mtime = get_file_mtime(filepath)
	cache.cache_parse(filepath, {
		mtime = mtime,
		tasks = repaired_tasks,
		roots = roots,
		id_to_task = repaired_id_to_task,
	})

	return repaired_tasks, repaired_id_to_task
end

return M
