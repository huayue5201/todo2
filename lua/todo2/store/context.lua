-- lua/todo2/store/context.lua
-- 上下文模块 - 精简版

local M = {}

local config = require("todo2.config")

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------
local function normalize(s)
	if not s then
		return ""
	end
	-- 移除注释
	s = s:gsub("%-%-.*$", "")
	s = s:gsub("^%s+", "")
	s = s:gsub("%s+$", "")
	s = s:gsub("%s+", " ")
	return s
end

local function hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 131 + s:byte(i)) % 2 ^ 31
	end
	return tostring(h)
end

--- 获取配置的上下文行数
local function get_context_lines()
	return config.get("context_lines") or 3
end

--- 提取代码结构信息
local function extract_struct(lines)
	local path = {}

	for _, line in ipairs(lines) do
		local l = normalize(line)

		-- 函数定义
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

		-- 类/表定义
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

--- 获取上下文行的范围
local function get_context_range(target_line, total_lines, context_lines)
	-- 计算前后各取多少行
	local before = math.floor((context_lines - 1) / 2)
	local after = context_lines - 1 - before

	local start_line = math.max(0, target_line - before)
	local end_line = math.min(total_lines - 1, target_line + after)

	-- 如果边界不足，向另一端扩展
	if end_line - start_line + 1 < context_lines then
		if start_line == 0 then
			end_line = math.min(total_lines - 1, start_line + context_lines - 1)
		elseif end_line == total_lines - 1 then
			start_line = math.max(0, end_line - context_lines + 1)
		end
	end

	-- 计算每行相对于目标行的偏移量
	local offsets = {}
	for i = start_line, end_line do
		table.insert(offsets, i - target_line)
	end

	return start_line, end_line, offsets
end

----------------------------------------------------------------------
-- 核心 API
----------------------------------------------------------------------

--- 从缓冲区构建上下文
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @return table
function M.build_from_buffer(bufnr, lnum)
	local context_lines = get_context_lines()
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 转换为0-based索引
	local target_line = lnum - 1

	-- 获取上下文范围
	local start_line, end_line, offsets = get_context_range(target_line, line_count, context_lines)

	-- 读取上下文行
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)

	-- 构建行映射
	local raw_context = {}
	local normalized_lines = {}

	for i, line in ipairs(lines) do
		local offset = offsets[i]
		raw_context[offset] = line
		normalized_lines[offset] = normalize(line)
	end

	-- 构建窗口字符串（按顺序拼接）
	local window_parts = {}
	for _, offset in ipairs(offsets) do
		table.insert(window_parts, normalized_lines[offset])
	end
	local window = table.concat(window_parts, "\n")
	local window_hash = hash(window)

	-- 提取结构信息
	local struct_path = extract_struct(lines)

	-- 构建指纹
	local fingerprint = {
		hash = hash(window_hash .. (struct_path or "")),
		struct = struct_path,
		window_hash = window_hash,
		offsets = offsets,
		context_lines = context_lines,
	}

	-- 添加行映射（便于匹配）
	for offset, line in pairs(normalized_lines) do
		fingerprint[offset] = line
	end

	return {
		raw = raw_context,
		fingerprint = fingerprint,
	}
end

--- 从文件路径构建上下文（辅助函数）
--- @param filepath string 文件路径
--- @param lnum number 行号（1-based）
--- @return table|nil
function M.build_from_file(filepath, lnum)
	if not filepath or not lnum then
		return nil
	end

	-- 尝试获取已加载的缓冲区
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name == filepath then
				return M.build_from_buffer(bufnr, lnum)
			end
		end
	end

	-- 如果缓冲区未加载，从文件读取
	if vim.fn.filereadable(filepath) == 0 then
		return nil
	end

	local lines = vim.fn.readfile(filepath)
	if #lines == 0 or lnum < 1 or lnum > #lines then
		return nil
	end

	-- 手动构建上下文，不使用 build_from_buffer
	local context_lines = get_context_lines()
	local before = math.floor((context_lines - 1) / 2)
	local after = context_lines - 1 - before

	-- 计算范围（1-based）
	local start_line = math.max(1, lnum - before)
	local end_line = math.min(#lines, lnum + after)

	-- 调整范围以满足需要的行数
	if end_line - start_line + 1 < context_lines then
		if start_line == 1 then
			end_line = math.min(#lines, start_line + context_lines - 1)
		elseif end_line == #lines then
			start_line = math.max(1, end_line - context_lines + 1)
		end
	end

	-- 收集上下文行
	local raw_context = {}
	local normalized_lines = {}
	local lines_in_context = {}

	for i = start_line, end_line do
		local line = lines[i]
		table.insert(lines_in_context, line)
	end

	-- 计算偏移量
	local offsets = {}
	for i = start_line, end_line do
		table.insert(offsets, i - lnum)
	end

	-- 构建行映射
	for i, line in ipairs(lines_in_context) do
		local offset = offsets[i]
		raw_context[offset] = line
		normalized_lines[offset] = normalize(line)
	end

	-- 构建窗口字符串
	local window_parts = {}
	for _, offset in ipairs(offsets) do
		table.insert(window_parts, normalized_lines[offset])
	end
	local window = table.concat(window_parts, "\n")
	local window_hash = hash(window)

	-- 提取结构信息
	local struct_path = extract_struct(lines_in_context)

	-- 构建指纹
	local fingerprint = {
		hash = hash(window_hash .. (struct_path or "")),
		struct = struct_path,
		window_hash = window_hash,
		offsets = offsets,
		context_lines = context_lines,
	}

	-- 添加行映射
	for offset, line in pairs(normalized_lines) do
		fingerprint[offset] = line
	end

	return {
		raw = raw_context,
		fingerprint = fingerprint,
	}
end

--- 匹配两个上下文
--- @param ctx1 table
--- @param ctx2 table
--- @return boolean
function M.match(ctx1, ctx2)
	if not ctx1 or not ctx2 then
		return false
	end

	-- 提取指纹
	local fp1 = ctx1.fingerprint or ctx1
	local fp2 = ctx2.fingerprint or ctx2

	-- 精确哈希匹配
	if fp1.hash and fp2.hash and fp1.hash == fp2.hash then
		return true
	end

	-- 结构路径匹配
	if fp1.struct and fp2.struct and fp1.struct == fp2.struct then
		return true
	end

	-- 如果都有偏移量信息，使用偏移量匹配
	if fp1.offsets and fp2.offsets then
		return M._match_by_offsets(fp1, fp2)
	end

	-- 如果没有偏移量信息，尝试匹配当前行
	if fp1[0] and fp2[0] and fp1[0] == fp2[0] then
		return true
	end

	return false
end

--- 基于偏移量的匹配
--- @param fp1 table
--- @param fp2 table
--- @return boolean
function M._match_by_offsets(fp1, fp2)
	-- 找出共同的偏移量
	local common_offsets = {}
	for _, offset in ipairs(fp1.offsets) do
		for _, offset2 in ipairs(fp2.offsets) do
			if offset == offset2 then
				table.insert(common_offsets, offset)
				break
			end
		end
	end

	if #common_offsets == 0 then
		return false
	end

	-- 计算匹配得分
	local total_score = 0
	local max_score = #common_offsets * 2 -- 当前行权重更高

	for _, offset in ipairs(common_offsets) do
		local line1 = fp1[offset]
		local line2 = fp2[offset]

		if line1 and line2 and line1 == line2 then
			if offset == 0 then
				total_score = total_score + 2 -- 当前行权重更高
			else
				total_score = total_score + 1
			end
		end
	end

	-- 要求至少50%的匹配度
	return total_score >= max_score * 0.5
end

return M
