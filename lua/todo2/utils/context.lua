-- lua/todo2/utils/context.lua
-- 精简版：只保留核心功能
-- 修复：确保 build_from_buffer 正常工作

-- TODO:ref:c36f7c
local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local hash_utils = require("todo2.utils.hash")

local VERSION = 2

---------------------------------------------------------------------
-- 私有辅助函数
---------------------------------------------------------------------
local function get_context_lines()
	return config.get("context_lines") or 5
end

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

local function get_context_range(target_line, total_lines, context_lines)
	-- 如果文件行数少于上下文行数，返回所有行
	if total_lines <= context_lines then
		return {
			start_line = 0,
			end_line = total_lines - 1,
			lines_before = target_line,
			lines_after = total_lines - 1 - target_line,
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

	return {
		start_line = start_line,
		end_line = end_line,
		lines_before = target_line - start_line,
		lines_after = end_line - target_line,
	}
end

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

	-- 内联 extract_struct
	local struct_path = nil
	if #struct_parts > 0 then
		local path = {}
		for _, line_content in ipairs(struct_parts) do
			local normalized = format.normalize_code_line(line_content, { keep_indent = true })

			-- 函数定义
			local f1 = normalized:match("^%s*function%s+([%w_%.]+)%s*%(")
			if f1 then
				table.insert(path, "func:" .. f1)
			end

			-- 局部函数
			local f2 = normalized:match("^%s*local%s+function%s+([%w_%.]+)")
			if f2 then
				table.insert(path, "local_func:" .. f2)
			end

			-- 赋值函数
			local f3 = normalized:match("^%s*([%w_%.]+)%s*=%s*function%s*%(")
			if f3 then
				table.insert(path, "assign_func:" .. f3)
			end

			-- 类/表
			local c1 = normalized:match("^%s*([%w_]+)%s*=%s*{}$")
			if c1 then
				table.insert(path, "class:" .. c1)
			end

			-- 方法
			local m1, m2 = normalized:match("^%s*function%s+([%w_%.]+):([%w_]+)%s*%(")
			if m1 and m2 then
				table.insert(path, "method:" .. m1 .. ":" .. m2)
			end
		end
		if #path > 0 then
			struct_path = table.concat(path, " > ")
		end
	end

	return {
		hash = hash_utils.combine(window_hash, struct_path or "", tostring(target_line_num)),
		struct = struct_path,
		window_hash = window_hash,
		line_count = #lines,
	}
end

---------------------------------------------------------------------
-- 核心公共 API
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

	-- 构建行数据，确保 offset 相对于目标行
	local lines = {}
	for i, content in ipairs(raw_lines) do
		local current_line_num = safe_start + i + 1 -- 转换为1-based
		local offset = current_line_num - lnum -- 相对于目标行的偏移

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
		target_line = lnum,
		range_info = {
			requested_lines = context_lines,
			actual_lines = #lines,
			start_line = safe_start + 1,
			end_line = safe_end + 1,
			target_line = lnum,
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

	local lines1 = ctx1.lines or {}
	local lines2 = ctx2.lines or {}

	if #lines1 == 0 or #lines2 == 0 then
		return 0
	end

	-- 优先匹配目标行（offset=0的行）
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
			local line = line1 or line2
			if line and line.normalized == format.config.EMPTY_LINE_MARKER then
				total_score = total_score + weight * 0.2
			end
		end
	end

	if max_score == 0 then
		return 0
	end

	return math.floor((total_score / max_score) * 100)
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

return M