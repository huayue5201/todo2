-- lua/todo2/store/context.lua
--- @module todo2.store.context

local M = {}

local config = require("todo2.config") -- 引入配置模块

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------
local function normalize(s)
	if not s then
		return ""
	end
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
	local ctx_config = config.get("context_lines") or {}
	return ctx_config or 3 -- 默认3行（上一行、当前行、下一行）
end

--- 提取代码结构信息（支持多行）
local function extract_struct(lines)
	local path = {}

	for _, line in ipairs(lines) do
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

--- 获取上下文行的范围
--- @param target_line number 目标行号（0-based）
--- @param total_lines number 总行数
--- @param context_lines number 配置的上下文行数
--- @return number start_line, number end_line, table offsets
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
-- 上下文构建与匹配
----------------------------------------------------------------------
--- 构建上下文指纹（支持配置行数）
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @return Context
function M.build_from_buffer(bufnr, lnum)
	local context_lines = get_context_lines()
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 转换为0-based索引
	local target_line = lnum - 1

	-- 获取上下文范围
	local start_line, end_line, offsets = get_context_range(target_line, line_count, context_lines)

	-- 读取上下文行
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)

	-- 构建原始上下文（包含偏移信息）
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

	-- 构建返回结果
	local ctx = {
		raw = raw_context,
		fingerprint = {
			hash = hash(window_hash .. (struct_path or "")),
			struct = struct_path,
			window_hash = window_hash,
			offsets = offsets,
			context_lines = context_lines,
		},
	}

	-- 为了兼容旧版，也保留 n_prev/n_curr/n_next（如果存在的话）
	if offsets[1] == -1 and offsets[2] == 0 and offsets[3] == 1 then
		ctx.fingerprint.n_prev = normalized_lines[-1] or ""
		ctx.fingerprint.n_curr = normalized_lines[0] or ""
		ctx.fingerprint.n_next = normalized_lines[1] or ""
	end

	return ctx
end

--- 兼容旧版的构建函数
function M.build(prev, curr, next)
	local context_lines = get_context_lines()

	-- 如果配置不是3行，给出警告
	if context_lines ~= 3 then
		vim.notify(
			"context.build() 仅支持3行上下文，但配置为 "
				.. context_lines
				.. " 行。建议使用 build_from_buffer()",
			vim.log.levels.WARN
		)
	end

	prev = prev or ""
	curr = curr or ""
	next = next or ""

	local n_prev = normalize(prev)
	local n_curr = normalize(curr)
	local n_next = normalize(next)

	local window = table.concat({ n_prev, n_curr, n_next }, "\n")
	local window_hash = hash(window)

	local struct_path = extract_struct({ prev, curr, next })

	return {
		raw = { prev = prev, curr = curr, next = next },
		fingerprint = {
			hash = hash(window_hash .. (struct_path or "")),
			struct = struct_path,
			n_prev = n_prev,
			n_curr = n_curr,
			n_next = n_next,
			window_hash = window_hash,
			context_lines = 3,
		},
	}
end

--- 匹配两个上下文
--- @param old_ctx Context
--- @param new_ctx Context
--- @return boolean
function M.match(old_ctx, new_ctx)
	if not old_ctx or not new_ctx then
		return false
	end

	local old_fp, new_fp = old_ctx, new_ctx

	if old_ctx.fingerprint then
		old_fp = old_ctx.fingerprint
	end

	if new_ctx.fingerprint then
		new_fp = new_ctx.fingerprint
	end

	if not old_fp or not new_fp then
		return false
	end

	-- 如果上下文行数配置不同，尝试转换
	if old_fp.context_lines ~= new_fp.context_lines then
		return M._match_different_context(old_fp, new_fp)
	end

	-- 精确哈希匹配
	if old_fp.hash == new_fp.hash then
		return true
	end

	-- 结构路径匹配
	if old_fp.struct and new_fp.struct and old_fp.struct == new_fp.struct then
		return true
	end

	-- 对于3行上下文，使用原有的评分机制
	if old_fp.context_lines == 3 and new_fp.context_lines == 3 then
		local score = 0
		if old_fp.n_curr == new_fp.n_curr then
			score = score + 2
		end
		if old_fp.n_prev == new_fp.n_prev then
			score = score + 1
		end
		if old_fp.n_next == new_fp.n_next then
			score = score + 1
		end
		return score >= 2
	end

	-- 对于其他行数，使用更通用的匹配策略
	return M._match_generic(old_fp, new_fp)
end

--- 通用上下文匹配（适用于任意行数）
function M._match_generic(fp1, fp2)
	if not fp1.offsets or not fp2.offsets then
		return false
	end

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
		local line1 = fp1["line_" .. offset] or fp1[offset] -- 兼容不同存储方式
		local line2 = fp2["line_" .. offset] or fp2[offset]

		if line1 == line2 then
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

--- 匹配不同行数配置的上下文
function M._match_different_context(fp1, fp2)
	-- 尝试找到共同的行（通过内容匹配）
	local lines1 = {}
	local lines2 = {}

	-- 收集所有行
	for k, v in pairs(fp1) do
		if type(k) == "number" or (type(k) == "string" and k:match("^[-]?%d+$")) then
			lines1[tonumber(k)] = v
		end
	end

	for k, v in pairs(fp2) do
		if type(k) == "number" or (type(k) == "string" and k:match("^[-]?%d+$")) then
			lines2[tonumber(k)] = v
		end
	end

	-- 如果都没有行信息，回退到哈希比较
	if #lines1 == 0 or #lines2 == 0 then
		return fp1.hash == fp2.hash
	end

	-- 尝试匹配当前行
	if lines1[0] and lines2[0] and lines1[0] == lines2[0] then
		return true
	end

	return false
end

return M
