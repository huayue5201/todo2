-- lua/todo2/store/context.lua (修复上下文和目标行匹配问题)

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local hash_utils = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local VERSION = 2

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function get_context_lines()
	return config.get("context_lines") or 5 -- 改为5行
end

--- 提取代码结构信息
local function extract_struct(lines)
	local path = {}

	for _, line in ipairs(lines) do
		local normalized = format.normalize_code_line(line, { keep_indent = true })

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

		local c1 = normalized:match("^%s*([%w_]+)%s*=%s*{}$")
		if c1 then
			table.insert(path, "class:" .. c1)
		end

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

--- ⭐ 修复1：改进的上下文范围计算（确保目标行在中间）
--- @param target_line number 目标行号（0-based）
--- @param total_lines number 总行数
--- @param context_lines number 上下文行数
--- @return table { start_line, end_line, lines_before, lines_after }
local function get_context_range(target_line, total_lines, context_lines)
	-- 如果文件行数少于上下文行数，返回所有行
	if total_lines <= context_lines then
		return {
			start_line = 0,
			end_line = total_lines - 1,
			lines_before = target_line,
			lines_after = total_lines - 1 - target_line,
			actual_lines = total_lines,
		}
	end

	-- 确保 context_lines 是奇数，这样目标行在中间
	if context_lines % 2 == 0 then
		context_lines = context_lines + 1
	end

	-- 计算前后各取多少行
	local lines_before = math.floor(context_lines / 2)
	local lines_after = context_lines - lines_before - 1

	-- 计算起始和结束行（0-based）
	local start_line = target_line - lines_before
	local end_line = target_line + lines_after

	-- 处理边界情况：如果起始行小于0
	if start_line < 0 then
		start_line = 0
		end_line = math.min(total_lines - 1, end_line + math.abs(start_line))
	end

	-- 处理边界情况：如果结束行超出范围
	if end_line >= total_lines then
		end_line = total_lines - 1
		start_line = math.max(0, start_line - (end_line - (total_lines - 1)))
	end

	local actual_lines = end_line - start_line + 1
	lines_before = target_line - start_line
	lines_after = end_line - target_line

	return {
		start_line = start_line,
		end_line = end_line,
		lines_before = lines_before,
		lines_after = lines_after,
		actual_lines = actual_lines,
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

--- ⭐ 修复2：计算指纹（确保包含目标行）
--- @param lines table 行数据列表（包含 content 和 normalized）
--- @param target_line_num number 目标行号（1-based）
--- @return table 指纹信息
local function calculate_fingerprint(lines, target_line_num)
	local window_parts = {}
	local struct_parts = {}

	for _, line in ipairs(lines) do
		table.insert(window_parts, line.normalized)

		if
			line.normalized ~= format.config.EMPTY_LINE_MARKER
			and line.normalized ~= format.config.NORMAL_LINE_MARKER
		then
			table.insert(struct_parts, line.content)
		end
	end

	local window = table.concat(window_parts, "\n")
	local window_hash = hash_utils.hash(window)

	local struct_path = nil
	if #struct_parts > 0 then
		struct_path = extract_struct(struct_parts)
	end

	return {
		hash = hash_utils.combine(window_hash, struct_path or "", tostring(target_line_num)),
		struct = struct_path,
		window_hash = window_hash,
		line_count = #lines,
		target_offset = 0,
	}
end

---------------------------------------------------------------------
-- ⭐ 修复3：从缓冲区构建上下文（确保目标行正确）
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

	-- 获取上下文范围（使用 0-based 行号）
	local range = get_context_range(lnum - 1, line_count, context_lines)

	-- 安全获取行内容
	local safe_start = math.max(0, range.start_line)
	local safe_end = math.min(line_count - 1, range.end_line)
	local raw_lines = vim.api.nvim_buf_get_lines(bufnr, safe_start, safe_end + 1, false)

	-- ⭐ 修复：构建行数据，确保 offset 相对于目标行
	local lines = {}
	for i, content in ipairs(raw_lines) do
		local current_line_num = safe_start + i -- 转换为1-based
		local offset = current_line_num - lnum -- 相对于目标行的偏移

		-- 调试输出（仅在需要时）
		if vim.g.todo_debug then
			print(string.format("行 %d: offset=%d, 目标行=%d", current_line_num, offset, lnum))
		end

		table.insert(lines, {
			offset = offset,
			content = content,
			normalized = format.normalize_code_line(content),
		})
	end

	-- 优先使用传入的 filepath
	local target_file = filepath
	if not target_file or target_file == "" then
		target_file = vim.api.nvim_buf_get_name(bufnr) or ""
	end

	-- 计算指纹（传入目标行号确保唯一性）
	local fingerprint = calculate_fingerprint(lines, lnum)

	-- 元数据中记录准确的信息
	local metadata = {
		created_at = os.time(),
		context_lines = context_lines,
		line_count = #lines,
		original_file = target_file,
		source_bufnr = bufnr,
		target_line = lnum, -- 明确记录目标行
		range_info = {
			requested_lines = context_lines,
			actual_lines = #lines,
			start_line = safe_start + 1,
			end_line = safe_end + 1,
			target_line = lnum,
		},
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

	if filepath and filepath ~= "" then
		pcall(vim.api.nvim_buf_set_name, temp_buf, filepath)
	end

	local line_num = target_line

	if not line_num then
		if not prev and not next then
			line_num = 1
		elseif not prev then
			line_num = 1
		elseif not next then
			line_num = 2
		else
			line_num = 2
		end
	end

	local ctx = M.build_from_buffer(temp_buf, line_num, filepath)

	vim.api.nvim_buf_delete(temp_buf, { force = true })

	return ctx
end

--- 通过内容锚定构建上下文
--- @param bufnr number 缓冲区编号
--- @param pattern string 匹配模式
--- @param filepath string|nil 文件路径
--- @return table|nil 上下文对象
function M.build_from_pattern(bufnr, pattern, filepath)
	if not bufnr or not pattern then
		vim.notify("build_from_pattern 缺少必要参数", vim.log.levels.ERROR)
		return nil
	end

	local target_line = find_target_line_by_content(bufnr, pattern)
	if not target_line then
		vim.notify("未找到匹配内容：" .. pattern, vim.log.levels.WARN)
		return nil
	end

	return M.build_from_buffer(bufnr, target_line, filepath)
end

--- ⭐ 修复4：改进相似度计算，优先匹配目标行
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

	local lines1 = ctx1.lines or {}
	local lines2 = ctx2.lines or {}

	if #lines1 == 0 or #lines2 == 0 then
		return 0
	end

	-- ⭐ 优先匹配目标行（offset=0的行）
	local target1 = nil
	local target2 = nil
	for _, line in ipairs(lines1) do
		if line.offset == 0 then
			target1 = line
			break
		end
	end
	for _, line in ipairs(lines2) do
		if line.offset == 0 then
			target2 = line
			break
		end
	end

	-- 如果目标行内容完全不同，直接返回低分
	if target1 and target2 and target1.normalized ~= target2.normalized then
		-- 但如果是空行匹配，给少量分
		if
			target1.normalized == format.config.EMPTY_LINE_MARKER
			and target2.normalized == format.config.EMPTY_LINE_MARKER
		then
			-- 继续计算其他行
		else
			return 20 -- 目标行不同，相似度很低
		end
	end

	-- 建立索引
	local map1 = {}
	for _, line in ipairs(lines1) do
		map1[line.offset] = line
	end

	local map2 = {}
	for _, line in ipairs(lines2) do
		map2[line.offset] = line
	end

	local total_score = 0
	local max_score = 0

	-- 找出所有可能的偏移
	local all_offsets = {}
	for offset, _ in pairs(map1) do
		all_offsets[offset] = true
	end
	for offset, _ in pairs(map2) do
		all_offsets[offset] = true
	end

	-- 按offset排序
	local sorted_offsets = {}
	for offset, _ in pairs(all_offsets) do
		table.insert(sorted_offsets, offset)
	end
	table.sort(sorted_offsets)

	for _, offset in ipairs(sorted_offsets) do
		local line1 = map1[offset]
		local line2 = map2[offset]

		-- 目标行权重更高
		local weight = (offset == 0) and 3 or 1
		max_score = max_score + weight

		if line1 and line2 then
			if line1.normalized == line2.normalized then
				total_score = total_score + weight
			elseif
				line1.normalized == format.config.EMPTY_LINE_MARKER
				and line2.normalized == format.config.EMPTY_LINE_MARKER
			then
				total_score = total_score + weight * 0.5
			end
		elseif line1 or line2 then
			-- 只有一边有行，给少量分
			if line1 and line1.normalized == format.config.EMPTY_LINE_MARKER then
				total_score = total_score + weight * 0.2
			elseif line2 and line2.normalized == format.config.EMPTY_LINE_MARKER then
				total_score = total_score + weight * 0.2
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

--- ⭐ 修复5：验证上下文和目标行是否一致
--- @param ctx table 上下文对象
--- @param expected_line number 期望的行号
--- @return boolean, string
function M.validate_context(ctx, expected_line)
	if not ctx then
		return false, "上下文为空"
	end

	if ctx.target_line ~= expected_line then
		return false, string.format("上下文目标行 %d 与期望行 %d 不一致", ctx.target_line, expected_line)
	end

	-- 检查目标行内容是否正确
	local target_content = nil
	for _, line in ipairs(ctx.lines or {}) do
		if line.offset == 0 then
			target_content = line.content
			break
		end
	end

	if not target_content then
		return false, "上下文中没有目标行"
	end

	return true, "上下文有效"
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
