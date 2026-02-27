-- lua/todo2/store/context.lua
-- 上下文管理模块（函数式风格，统一代码风格）

local M = {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local VERSION = 2 -- 上下文数据结构版本

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function normalize(s)
	if not s then
		return ""
	end

	-- 创建副本用于规范化
	local normalized = s

	-- 检测注释类型并保留标记
	if normalized:match("^%s*%-%-") then
		-- Lua/Rust/SQL 注释行，保留 "--" 作为结构标记
		normalized = normalized:gsub("%-%-.*$", "--")
	elseif normalized:match("^%s*//") then
		-- C/C++/JS/Rust 注释，保留 "//"
		normalized = normalized:gsub("//.*$", "//")
	elseif normalized:match("^%s*#") then
		-- Python/Ruby/Shell 注释，保留 "#"
		normalized = normalized:gsub("#.*$", "#")
	else
		-- 非注释行，正常移除行内注释
		normalized = normalized:gsub("%-%-.*$", "")
		normalized = normalized:gsub("//.*$", "")
		normalized = normalized:gsub("#.*$", "")
	end

	-- 规范化空白
	normalized = normalized:gsub("^%s+", "")
	normalized = normalized:gsub("%s+$", "")
	normalized = normalized:gsub("%s+", " ")

	return normalized
end

local function hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 131 + s:byte(i)) % 2 ^ 31
	end
	return tostring(h)
end

local function get_context_lines()
	return config.get("context_lines") or 3
end

--- 提取代码结构信息
local function extract_struct(lines)
	local path = {}
	local line_index = math.floor(#lines / 2) + 1

	for i, line in ipairs(lines) do
		local l = normalize(line)

		local f1 = l:match("^function%s+([%w_%.]+)%s*%(")
		if f1 then
			table.insert(path, "func:" .. f1)
		end

		local f2 = l:match("^local%s+function%s+([%w_%.]+)")
		if f2 then
			table.insert(path, "local_func:" .. f2)
		end

		local f3 = l:match("^([%w_%.]+)%s*=%s*function%s*%(")
		if f3 then
			table.insert(path, "assign_func:" .. f3)
		end

		local c1 = l:match("^([%w_]+)%s*=%s*{}$")
		if c1 then
			table.insert(path, "class:" .. c1)
		end
	end

	if #path == 0 then
		return nil
	end
	return table.concat(path, " > ")
end

--- 计算上下文范围
--- @param target_line number 目标行号（0-based）
--- @param total_lines number 总行数
--- @param context_lines number 上下文行数
--- @return table { start_line, end_line, offsets }
local function get_context_range(target_line, total_lines, context_lines)
	local before = math.floor((context_lines - 1) / 2)
	local after = context_lines - 1 - before

	local start_line = math.max(0, target_line - before)
	local end_line = math.min(total_lines - 1, target_line + after)

	-- 补全上下文行数（当文件开头/结尾不足时）
	if end_line - start_line + 1 < context_lines then
		if start_line == 0 then
			end_line = math.min(total_lines - 1, start_line + context_lines - 1)
		elseif end_line == total_lines - 1 then
			start_line = math.max(0, end_line - context_lines + 1)
		end
	end

	-- 计算每个实际行号对应的偏移量（相对于目标行）
	local offsets = {}
	for line_num = start_line, end_line do
		table.insert(offsets, line_num - target_line)
	end

	return {
		start_line = start_line,
		end_line = end_line,
		offsets = offsets,
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

--- 计算指纹
local function calculate_fingerprint(lines)
	local window_parts = {}
	for _, line in ipairs(lines) do
		table.insert(window_parts, line.normalized)
	end
	local window = table.concat(window_parts, "\n")
	local window_hash = hash(window)

	local raw_line_contents = {}
	for _, line in ipairs(lines) do
		table.insert(raw_line_contents, line.content)
	end
	local struct_path = extract_struct(raw_line_contents)

	return {
		hash = hash(window_hash .. (struct_path or "")),
		struct = struct_path,
		window_hash = window_hash,
		line_count = #lines,
		target_offset = 0,
	}
end

---------------------------------------------------------------------
-- 核心 API
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

	local context_lines = get_context_lines()
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 保持lnum为1-based，只在传入get_context_range时减1转换为0-based
	local target_line = lnum
	local range = get_context_range(target_line - 1, line_count, context_lines)

	-- 安全校验：避免nvim_buf_get_lines越界
	local safe_start = math.max(0, range.start_line)
	local safe_end = math.min(line_count - 1, range.end_line)
	local raw_lines = vim.api.nvim_buf_get_lines(bufnr, safe_start, safe_end + 1, false)

	-- 构建行数据
	local lines = {}
	for i, content in ipairs(raw_lines) do
		local offset = range.offsets[i] or (safe_start + i - 1) - (target_line - 1)
		table.insert(lines, {
			offset = offset,
			content = content,
			normalized = normalize(content),
		})
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

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, { prev or "", curr or "", next or "" })

	-- 使用传入的 target_line，默认为2保持兼容
	local line_num = target_line or 2

	-- 设置临时缓冲区的名称
	if filepath and filepath ~= "" then
		pcall(vim.api.nvim_buf_set_name, temp_buf, filepath)
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

--- 计算两个上下文的相似度
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
		max_score = max_score + (line.offset == 0 and 2 or 1)
	end

	-- 比较
	for _, line in ipairs(ctx2.lines or {}) do
		local line1 = lines1[line.offset]
		if line1 then
			if line1.normalized == line.normalized then
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
	return M.similarity(ctx1, ctx2) >= 60
end

return M
