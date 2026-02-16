-- lua/todo2/store/context.lua
--- @module todo2.store.context
--- 上下文管理模块（纯数组版本）

local M = {}

local config = require("todo2.config")

----------------------------------------------------------------------
-- 常量定义
----------------------------------------------------------------------
local VERSION = 2 -- 上下文数据结构版本

----------------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------------
local function normalize(s)
	if not s then
		return ""
	end
	-- 移除行内注释
	s = s:gsub("%-%-.*$", "")
	s = s:gsub("//.*$", "")
	s = s:gsub("#.*$", "")
	-- 规范化空白
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
local function get_context_range(target_line, total_lines, context_lines)
	local before = math.floor((context_lines - 1) / 2)
	local after = context_lines - 1 - before

	local start_line = math.max(0, target_line - before)
	local end_line = math.min(total_lines - 1, target_line + after)

	if end_line - start_line + 1 < context_lines then
		if start_line == 0 then
			end_line = math.min(total_lines - 1, start_line + context_lines - 1)
		elseif end_line == total_lines - 1 then
			start_line = math.max(0, end_line - context_lines + 1)
		end
	end

	local offsets = {}
	for i = start_line, end_line do
		table.insert(offsets, i - target_line)
	end

	return {
		start_line = start_line,
		end_line = end_line,
		offsets = offsets,
	}
end

----------------------------------------------------------------------
-- Context 类定义
----------------------------------------------------------------------

--- @class ContextLine
--- @field offset number 相对于目标行的偏移量
--- @field content string 原始内容
--- @field normalized string 规范化后的内容

--- @class Context
--- @field version number 数据结构版本
--- @field lines ContextLine[] 有序的上下文行列表
--- @field target_line number 目标行号（1-based）
--- @field target_file string 目标文件路径
--- @field fingerprint table 快速匹配指纹
--- @field metadata table 元数据

local Context = {}
Context.__index = Context

--- 创建新的 Context 实例
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @return Context
function Context.new(bufnr, lnum)
	local self = setmetatable({}, Context)

	local context_lines = get_context_lines()
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	local target_line = lnum - 1
	local range = get_context_range(target_line, line_count, context_lines)
	local raw_lines = vim.api.nvim_buf_get_lines(bufnr, range.start_line, range.end_line + 1, false)

	-- 构建有序的行列表
	self.lines = {}
	for i, content in ipairs(raw_lines) do
		local offset = range.offsets[i]
		table.insert(self.lines, {
			offset = offset,
			content = content,
			normalized = normalize(content),
		})
	end

	-- 元数据
	self.version = VERSION
	self.target_line = lnum
	self.target_file = vim.api.nvim_buf_get_name(bufnr)
	self.metadata = {
		created_at = os.time(),
		context_lines = context_lines,
		line_count = #self.lines,
	}

	-- 计算指纹
	self:_calculate_fingerprint()

	return self
end

--- 计算指纹（内部方法）
function Context:_calculate_fingerprint()
	local window_parts = {}
	for _, line in ipairs(self.lines) do
		table.insert(window_parts, line.normalized)
	end
	local window = table.concat(window_parts, "\n")
	local window_hash = hash(window)

	local raw_line_contents = {}
	for _, line in ipairs(self.lines) do
		table.insert(raw_line_contents, line.content)
	end
	local struct_path = extract_struct(raw_line_contents)

	self.fingerprint = {
		hash = hash(window_hash .. (struct_path or "")),
		struct = struct_path,
		window_hash = window_hash,
		line_count = #self.lines,
		target_offset = 0,
	}
end

--- 获取指定偏移量的行
--- @param offset number 偏移量
--- @return string|nil
function Context:get_line(offset)
	for _, line in ipairs(self.lines) do
		if line.offset == offset then
			return line.content
		end
	end
	return nil
end

--- 获取当前行内容
--- @return string|nil
function Context:get_current_line()
	return self:get_line(0)
end

--- 获取所有行内容（按顺序）
--- @return string[]
function Context:get_all_lines()
	local result = {}
	for _, line in ipairs(self.lines) do
		table.insert(result, line.content)
	end
	return result
end

--- 转换为可存储的表
--- @return table
function Context:to_storable()
	return {
		version = self.version,
		lines = self.lines,
		target_line = self.target_line,
		target_file = self.target_file,
		fingerprint = self.fingerprint,
		metadata = self.metadata,
	}
end

--- 从存储的数据恢复 Context 对象
--- @param data table 存储的上下文数据
--- @return Context|nil
function Context.from_storable(data)
	if not data or type(data) ~= "table" then
		return nil
	end

	-- 只接受新版格式
	if data.version ~= VERSION then
		return nil
	end

	local self = setmetatable({}, Context)
	self.version = data.version
	self.lines = data.lines or {}
	self.target_line = data.target_line
	self.target_file = data.target_file
	self.fingerprint = data.fingerprint
	self.metadata = data.metadata

	return self
end

--- 匹配另一个上下文
--- @param other Context|table 另一个上下文对象
--- @return boolean
function Context:match(other)
	if not other then
		return false
	end

	local other_ctx = other
	if not other.match then
		other_ctx = Context.from_storable(other)
	end

	if not other_ctx then
		return false
	end

	-- 快速路径：哈希匹配
	if self.fingerprint.hash == other_ctx.fingerprint.hash then
		return true
	end

	-- 结构路径匹配
	if
		self.fingerprint.struct
		and other_ctx.fingerprint.struct
		and self.fingerprint.struct == other_ctx.fingerprint.struct
	then
		return true
	end

	-- 慢速路径：逐行比较
	local matches = 0
	local total = 0

	local self_map = {}
	for _, line in ipairs(self.lines) do
		self_map[line.offset] = line
	end

	local other_map = {}
	for _, line in ipairs(other_ctx.lines) do
		other_map[line.offset] = line
	end

	for offset, self_line in pairs(self_map) do
		local other_line = other_map[offset]
		if other_line then
			total = total + 1
			if self_line.normalized == other_line.normalized then
				matches = matches + 1
			end
		end
	end

	return total > 0 and (matches / total) >= 0.6
end

--- 获取相似度评分
--- @param other Context|table 另一个上下文对象
--- @return number 相似度（0-100）
function Context:similarity(other)
	if not other then
		return 0
	end

	local other_ctx = other
	if not other.match then
		other_ctx = Context.from_storable(other)
	end

	if not other_ctx then
		return 0
	end

	if self.fingerprint.hash == other_ctx.fingerprint.hash then
		return 100
	end

	local total_score = 0
	local max_score = 0

	local self_map = {}
	for _, line in ipairs(self.lines) do
		self_map[line.offset] = line
		max_score = max_score + (line.offset == 0 and 2 or 1)
	end

	for _, line in ipairs(other_ctx.lines) do
		local self_line = self_map[line.offset]
		if self_line then
			if self_line.normalized == line.normalized then
				total_score = total_score + (line.offset == 0 and 2 or 1)
			end
		end
	end

	if max_score == 0 then
		return 0
	end

	return math.floor((total_score / max_score) * 100)
end

----------------------------------------------------------------------
-- 简化后的公共 API
----------------------------------------------------------------------

--- 构建上下文（新版）
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号（1-based）
--- @return Context
function M.build_from_buffer(bufnr, lnum)
	return Context.new(bufnr, lnum)
end

--- 构建上下文（兼容旧版调用，但返回新格式）
--- @param prev string 前一行
--- @param curr string 当前行
--- @param next string 后一行
--- @return table 新格式的上下文表
function M.build(prev, curr, next)
	local context_lines = get_context_lines()

	if context_lines ~= 3 then
		vim.notify("context.build() 已弃用，请使用 build_from_buffer()", vim.log.levels.WARN)
	end

	-- 模拟一个临时缓冲区来创建 Context
	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, { prev or "", curr or "", next or "" })

	local ctx = Context.new(temp_buf, 2) -- 第2行是当前行

	vim.api.nvim_buf_delete(temp_buf, { force = true })

	return ctx:to_storable()
end

--- 匹配两个上下文
--- @param ctx1 table|Context
--- @param ctx2 table|Context
--- @return boolean
function M.match(ctx1, ctx2)
	local c1 = ctx1.match and ctx1 or Context.from_storable(ctx1)
	local c2 = ctx2.match and ctx2 or Context.from_storable(ctx2)

	if not c1 or not c2 then
		return false
	end

	return c1:match(c2)
end

--- 获取当前行内容
--- @param ctx table|Context
--- @return string|nil
function M.get_current_line(ctx)
	if not ctx then
		return nil
	end

	if ctx.get_current_line then
		return ctx:get_current_line()
	end

	local c = Context.from_storable(ctx)
	return c and c:get_current_line()
end

--- 验证上下文数据是否有效
--- @param ctx any
--- @return boolean
function M.is_valid(ctx)
	if not ctx then
		return false
	end

	if ctx.version == VERSION and ctx.lines then
		return true
	end

	return false
end

return M
