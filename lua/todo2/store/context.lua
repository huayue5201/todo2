-- lua/todo2/store/context.lua
-- 上下文管理模块（完整修复版：正确处理空行和偏移）

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local hash_utils = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local VERSION = 2 -- 上下文数据结构版本

---------------------------------------------------------------------
-- 工具函数（context 特有的工具函数）
---------------------------------------------------------------------

local function get_context_lines()
	return config.get("context_lines") or 3
end

--- 提取代码结构信息
--- @param lines table 原始代码行列表
--- @return string|nil 结构路径
local function extract_struct(lines)
	local path = {}

	-- 使用格式工具规范化代码行，但保留缩进信息用于结构识别
	for _, line in ipairs(lines) do
		local normalized = format.normalize_code_line(line, { keep_indent = true })

		-- 提取函数定义
		local f1 = normalized:match("^%s*function%s+([%w_%.]+)%s*%(")
		if f1 then
			table.insert(path, "func:" .. f1)
		end

		local f2 = normalized:match("^%s*local%s+function%s+([%w_%.]+)")
		if f2 then
			table.insert(path, "local_func:" .. f2)
		end

		local f3 = normalized:match("^%s*([%w_%.]+)%s*=%s*function%s*%(")
		if f3 then
			table.insert(path, "assign_func:" .. f3)
		end

		-- 提取类/表定义
		local c1 = normalized:match("^%s*([%w_]+)%s*=%s*{}$")
		if c1 then
			table.insert(path, "class:" .. c1)
		end

		-- 提取方法定义（针对 Lua 的 : 语法）
		local m1, m2 = normalized:match("^%s*function%s+([%w_%.]+):([%w_]+)%s*%(")
		if m1 and m2 then
			table.insert(path, "method:" .. m1 .. ":" .. m2)
		end
	end

	if #path == 0 then
		return nil
	end
	return table.concat(path, " > ")
end

--- ⭐ 修复版：计算上下文范围（确保取目标行前后各2行）
--- @param target_line number 目标行号（0-based）
--- @param total_lines number 总行数
--- @param context_lines number 上下文行数
--- @return table { start_line, end_line, lines_before, lines_after }
local function get_context_range(target_line, total_lines, context_lines)
	-- 确保 context_lines 是奇数
	if context_lines % 2 == 0 then
		context_lines = context_lines + 1
	end

	-- 计算前后各取多少行
	local lines_before = math.floor(context_lines / 2) -- 当 context_lines=5 时，lines_before=2
	local lines_after = context_lines - lines_before - 1 -- lines_after=2

	-- 计算起始和结束行（0-based）
	local start_line = math.max(0, target_line - lines_before)
	local end_line = math.min(total_lines - 1, target_line + lines_after)

	-- 处理边界情况：如果前面行数不够，从后面补
	if start_line == 0 then
		local needed_lines = context_lines - (end_line - start_line + 1)
		end_line = math.min(total_lines - 1, end_line + needed_lines)
	end

	-- 处理边界情况：如果后面行数不够，从前面补
	if end_line == total_lines - 1 then
		local needed_lines = context_lines - (end_line - start_line + 1)
		start_line = math.max(0, start_line - needed_lines)
	end

	return {
		start_line = start_line,
		end_line = end_line,
		lines_before = target_line - start_line,
		lines_after = end_line - target_line,
	}
end

--- 校验行号有效性
local function validate_line_number(bufnr, lnum)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "缓冲区无效"
	end
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	if not lnum or lnum < 1 or lnum > total_lines then
		return false, string.format("行号%d超出范围（总行数：%d）", lnum or 0, total_lines)
	end
	return true, "行号有效"
end

--- 通过内容查找目标行号
local function find_target_line_by_content(bufnr, pattern)
	if not bufnr or not pattern or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for lnum, line_content in ipairs(lines) do
		if line_content:find(pattern, 1, true) then
			return lnum
		end
	end
	return nil
end

--- ⭐ 修复版：计算指纹（正确处理空行）
--- @param lines table 行数据列表（包含 content 和 normalized）
--- @return table 指纹信息
local function calculate_fingerprint(lines)
	local window_parts = {}
	local struct_parts = {}

	for _, line in ipairs(lines) do
		-- 使用 normalized 构建窗口哈希
		table.insert(window_parts, line.normalized)

		-- 构建结构路径时，跳过空行标记
		if
			line.normalized ~= format.config.EMPTY_LINE_MARKER
			and line.normalized ~= format.config.NORMAL_LINE_MARKER
		then
			table.insert(struct_parts, line.content)
		end
	end

	local window = table.concat(window_parts, "\n")
	local window_hash = hash_utils.hash(window)

	-- 提取结构信息（跳过空行）
	local struct_path = nil
	if #struct_parts > 0 then
		struct_path = extract_struct(struct_parts)
	end

	return {
		hash = hash_utils.combine(window_hash, struct_path or ""),
		struct = struct_path,
		window_hash = window_hash,
		line_count = #lines,
		target_offset = 0,
	}
end

---------------------------------------------------------------------
-- 从缓冲区构建上下文
---------------------------------------------------------------------
--- 从缓冲区构建上下文
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @param filepath string|nil 可选的文件路径
--- @return table|nil 上下文对象
function M.build_from_buffer(bufnr, lnum, filepath)
	-- 前置行号有效性校验
	local is_valid, msg = validate_line_number(bufnr, lnum)
	if not is_valid then
		vim.notify("创建上下文失败：" .. msg, vim.log.levels.ERROR)
		return nil
	end

	local context_lines = get_context_lines() -- 从配置获取，应该是3或5
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 获取上下文范围（使用 0-based 行号）
	local range = get_context_range(lnum - 1, line_count, context_lines)

	-- 安全获取行内容
	local safe_start = math.max(0, range.start_line)
	local safe_end = math.min(line_count - 1, range.end_line)
	local raw_lines = vim.api.nvim_buf_get_lines(bufnr, safe_start, safe_end + 1, false)

	-- ⭐ 修复：构建行数据，正确计算 offset
	local lines = {}
	for i, content in ipairs(raw_lines) do
		local current_line_num = safe_start + i - 1 -- 当前行号（0-based）

		-- ⭐ 修复点：offset 应该是相对于目标行的偏移
		-- 目标行 lnum 是 1-based，转换为 0-based 是 lnum - 1
		local offset = current_line_num - (lnum - 1) -- 这才是正确的偏移量

		table.insert(lines, {
			offset = offset,
			content = content,
			normalized = format.normalize_code_line(content),
		})
	end

	-- 调试输出
	if vim.g.todo_debug then
		print(string.format("目标行: %d, 范围: %d-%d, 行数: %d", lnum, safe_start + 1, safe_end + 1, #lines))
		for _, line in ipairs(lines) do
			print(string.format("  offset=%d: %s", line.offset, line.content:sub(1, 40)))
		end
	end

	-- 优先使用传入的 filepath
	local target_file = filepath
	if not target_file or target_file == "" then
		target_file = vim.api.nvim_buf_get_name(bufnr) or ""
	end

	-- 计算指纹
	local fingerprint = calculate_fingerprint(lines)

	-- 元数据
	local metadata = {
		created_at = os.time(),
		context_lines = context_lines,
		line_count = #lines,
		original_file = target_file,
		source_bufnr = bufnr,
		line_validation = {
			lnum = lnum,
			total_lines = line_count,
			is_valid = true,
		},
	}

	return {
		version = VERSION,
		lines = lines,
		target_line = lnum,
		target_file = target_file,
		fingerprint = fingerprint,
		metadata = metadata,
	}
end

--- 构建上下文（兼容旧版调用）
--- @param prev string 前一行
--- @param curr string 当前行
--- @param next string 后一行
--- @param filepath string|nil 文件路径（可选）
--- @param target_line number|nil 目标行号
--- @return table|nil 上下文对象
function M.build(prev, curr, next, filepath, target_line)
	local context_lines = get_context_lines()

	if context_lines ~= 3 then
		vim.notify("context.build() 已弃用，请使用 build_from_buffer()", vim.log.levels.WARN)
	end

	-- 创建临时缓冲区
	local lines = {}
	if prev then
		table.insert(lines, prev)
	end
	table.insert(lines, curr or "")
	if next then
		table.insert(lines, next)
	end

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	-- 设置临时缓冲区的名称
	if filepath and filepath ~= "" then
		pcall(vim.api.nvim_buf_set_name, temp_buf, filepath)
	end

	-- ⭐ 修复：如果传入了 target_line，直接使用；否则自动判断
	local line_num = target_line

	if not line_num then
		-- 自动判断目标行
		if not prev and not next then
			-- 只有当前行
			line_num = 1
		elseif not prev then
			-- 没有前一行，目标行是第1行
			line_num = 1
		elseif not next then
			-- 没有后一行，目标行是第2行
			line_num = 2
		else
			-- 有前后行，目标行是第2行
			line_num = 2
		end
	end

	local ctx = M.build_from_buffer(temp_buf, line_num, filepath)

	vim.api.nvim_buf_delete(temp_buf, { force = true })

	return ctx
end

--- 通过内容锚定构建上下文
--- @param bufnr number 缓冲区编号
--- @param pattern string 匹配模式（如 FIX:ref:c3d93c）
--- @param filepath string|nil 文件路径
--- @return table|nil 上下文对象
function M.build_from_pattern(bufnr, pattern, filepath)
	if not bufnr or not pattern then
		vim.notify("build_from_pattern 缺少必要参数", vim.log.levels.ERROR)
		return nil
	end

	-- 查找内容对应的真实行号
	local target_line = find_target_line_by_content(bufnr, pattern)
	if not target_line then
		vim.notify("未找到匹配内容：" .. pattern, vim.log.levels.WARN)
		return nil
	end

	-- 构建上下文
	return M.build_from_buffer(bufnr, target_line, filepath)
end

--- ⭐ 修复版：计算两个上下文的相似度（正确处理空行）
--- @param ctx1 table 上下文1
--- @param ctx2 table 上下文2
--- @return number 相似度百分比 (0-100)
function M.similarity(ctx1, ctx2)
	if not ctx1 or not ctx2 then
		return 0
	end

	-- 快速匹配：指纹相同
	if ctx1.fingerprint and ctx2.fingerprint and ctx1.fingerprint.hash == ctx2.fingerprint.hash then
		return 100
	end

	local total_score = 0
	local max_score = 0

	-- 建立索引
	local lines1 = {}
	for _, line in ipairs(ctx1.lines or {}) do
		lines1[line.offset] = line
		-- 空行也计入权重，但降低权重
		if line.normalized == format.config.EMPTY_LINE_MARKER then
			max_score = max_score + 0.5 -- 空行权重减半
		else
			max_score = max_score + (line.offset == 0 and 2 or 1)
		end
	end

	-- 比较
	for _, line in ipairs(ctx2.lines or {}) do
		local line1 = lines1[line.offset]
		if line1 then
			-- 特殊处理空行
			if
				line.normalized == format.config.EMPTY_LINE_MARKER
				and line1.normalized == format.config.EMPTY_LINE_MARKER
			then
				total_score = total_score + 0.5 -- 两个空行匹配
			elseif line.normalized == line1.normalized then
				total_score = total_score + (line.offset == 0 and 2 or 1)
			end
		end
	end

	if max_score == 0 then
		return 0
	end

	return math.floor((total_score / max_score) * 100)
end

--- 判断两个上下文是否匹配
--- @param ctx1 table 上下文1
--- @param ctx2 table 上下文2
--- @return boolean
function M.match(ctx1, ctx2)
	local config = require("todo2.config")
	local threshold = config.get("context.similarity_threshold") or 60
	return M.similarity(ctx1, ctx2) >= threshold
end

--- 获取上下文中的目标行内容
--- @param ctx table 上下文对象
--- @return string|nil 目标行内容
function M.get_target_line_content(ctx)
	if not ctx or not ctx.lines then
		return nil
	end

	for _, line in ipairs(ctx.lines) do
		if line.offset == 0 then
			return line.content
		end
	end

	return nil
end

--- 检查上下文是否包含任务行
--- @param ctx table 上下文对象
--- @return boolean
function M.contains_task(ctx)
	local target_content = M.get_target_line_content(ctx)
	if not target_content then
		return false
	end

	return format.is_task_line(target_content)
end

--- 从上下文中提取任务信息
--- @param ctx table 上下文对象
--- @return table|nil 任务信息
function M.extract_task_info(ctx)
	if not M.contains_task(ctx) then
		return nil
	end

	local target_content = M.get_target_line_content(ctx)
	return format.extract_task_context(target_content)
end

return M
