-- lua/todo2/ai/stream/protocol/line_range.lua
-- 流式解析器：支持跨 chunk 匹配协议标记
-- 状态机：WAITING_BEGIN → PARSING_HEADER → WAITING_HEADER → WAITING_CODE → PARSING_CODE → DONE

local M = {}

-- 状态定义
M.STATE = {
	WAITING_BEGIN = 1,
	PARSING_HEADER = 2,
	WAITING_HEADER = 3,
	WAITING_CODE = 4,
	PARSING_CODE = 5,
	DONE = 6,
}

-- 标记常量
local MARKERS = {
	BEGIN = "<<<TODO2_PATCH_BEGIN>>>",
	HEADER = "<<<TODO2_PATCH_HEADER>>>",
	CODE = "<<<TODO2_PATCH_CODE>>>",
	END = "<<<TODO2_PATCH_END>>>",
}

-- 计算标记长度
local MARKER_LENS = {
	[MARKERS.BEGIN] = #MARKERS.BEGIN,
	[MARKERS.HEADER] = #MARKERS.HEADER,
	[MARKERS.CODE] = #MARKERS.CODE,
	[MARKERS.END] = #MARKERS.END,
}

---@class ProtocolParser
---@field state number 当前状态
---@field buffer string 未处理的缓冲区
---@field header_buffer string header 累积缓冲区
---@field header table 解析出的 header 字段
---@field code_lines table[] 累积的代码行
---@field current_line string 当前行缓冲区
---@field result table|nil 最终解析结果
---@field last_marker string|nil 最后一个匹配的标记（用于调试）

---创建新的解析器
---@return ProtocolParser
function M.new()
	return {
		state = M.STATE.WAITING_BEGIN,
		buffer = "",
		header_buffer = "",
		header = {},
		code_lines = {},
		current_line = "",
		result = nil,
		last_marker = nil,
	}
end

---尝试匹配标记
---@param str string 字符串
---@param pos integer 起始位置
---@return string|nil marker
---@return integer next_pos
local function try_match_marker(str, pos)
	for marker, len in pairs(MARKER_LENS) do
		if str:sub(pos, pos + len - 1) == marker then
			return marker, pos + len
		end
	end
	return nil, pos
end

---解析 header 行
---@param line string
---@param header table
local function parse_header_line(line, header)
	if not line or line == "" then
		return
	end

	-- 解析 key=value 格式
	local key, value = line:match("^%s*([%w_]+)%s*=%s*(.+)$")
	if key and value then
		value = vim.trim(value)
		header[key] = value
	end
end

---完成解析，返回结果
---@param parser ProtocolParser
---@return table|nil
local function finalize(parser)
	if not parser.header.start_line or not parser.header.end_line then
		return nil
	end

	local result = {
		type = "replace",
		mode = "line_range",
		start_line = tonumber(parser.header.start_line),
		end_line = tonumber(parser.header.end_line),
		signature_hash = parser.header.signature_hash,
		signature = parser.header.signature,
	}

	-- 转换数字
	if result.start_line then
		result.start_line = result.start_line
	end
	if result.end_line then
		result.end_line = result.end_line
	end

	parser.result = result
	parser.state = M.STATE.DONE

	return result
end

---处理 WAITING_BEGIN 状态
---@param parser ProtocolParser
---@param pos integer 位置
---@param buffer string
---@return integer next_pos
local function handle_waiting_begin(parser, pos, buffer)
	-- 尝试匹配 BEGIN 标记
	local marker, next_pos = try_match_marker(buffer, pos)
	if marker == MARKERS.BEGIN then
		parser.state = M.STATE.PARSING_HEADER
		parser.last_marker = marker
		parser.header_buffer = ""
		parser.header = {}
		return next_pos
	end
	return pos + 1
end

---处理 PARSING_HEADER 状态（累积 header 内容直到遇到 HEADER 标记）
---@param parser ProtocolParser
---@param pos integer 位置
---@param buffer string
---@return integer next_pos
local function handle_parsing_header(parser, pos, buffer)
	-- 尝试匹配 HEADER 标记
	local marker, next_pos = try_match_marker(buffer, pos)
	if marker == MARKERS.HEADER then
		-- 完成 header 解析
		local header_lines = vim.split(parser.header_buffer, "\n", { plain = true })
		for _, line in ipairs(header_lines) do
			parse_header_line(line, parser.header)
		end
		parser.state = M.STATE.WAITING_CODE
		parser.last_marker = marker
		parser.header_buffer = ""
		return next_pos
	end

	-- 累积字符到 header_buffer
	local char = buffer:sub(pos, pos)
	parser.header_buffer = parser.header_buffer .. char
	return pos + 1
end

---@param parser ProtocolParser
---@param pos integer 位置
---@param buffer string
---@return integer next_pos
local function handle_waiting_code(parser, pos, buffer)
	local marker, next_pos = try_match_marker(buffer, pos)
	if marker == MARKERS.CODE then
		parser.state = M.STATE.PARSING_CODE
		parser.last_marker = marker
		parser.code_lines = {}
		return next_pos
	end

	-- 没有找到完整标记，但可能是跨 chunk 的部分标记
	-- 检查 buffer 从 pos 开始是否可能是某个标记的前缀
	local remaining = buffer:sub(pos)
	local is_partial = false

	for marker, len in pairs(MARKER_LENS) do
		local prefix = marker:sub(1, #remaining)
		if remaining == prefix then
			-- 这是一个标记的前缀，需要等待更多数据
			is_partial = true
			break
		end
	end

	if is_partial then
		-- 不消耗任何字符，等待下一个 chunk
		return pos
	end

	-- 不是标记的一部分，跳过当前字符
	return pos + 1
end

---处理 PARSING_CODE 状态（累积代码直到遇到 END 标记）
---@param parser ProtocolParser
---@param pos integer 位置
---@param buffer string
---@return integer next_pos
local function handle_parsing_code(parser, pos, buffer)
	local marker, next_pos = try_match_marker(buffer, pos)
	if marker == MARKERS.END then
		-- 完成解析
		local code = table.concat(parser.code_lines, "")
		finalize(parser)
		parser.result.code = code
		return next_pos
	end

	-- 累积代码
	local char = buffer:sub(pos, pos)
	parser.code_lines[#parser.code_lines + 1] = char
	return pos + 1
end

---向解析器喂入数据
---@param parser ProtocolParser
---@param chunk string 新数据块
---@return table|nil result 如果解析完成返回结果
function M.feed(parser, chunk)
	if not parser or parser.state == M.STATE.DONE then
		return parser and parser.result
	end

	-- 将新数据追加到缓冲区
	parser.buffer = parser.buffer .. chunk
	local pos = 1
	local buffer = parser.buffer

	while pos <= #buffer do
		if parser.state == M.STATE.WAITING_BEGIN then
			local new_pos = handle_waiting_begin(parser, pos, buffer)
			pos = new_pos
		elseif parser.state == M.STATE.PARSING_HEADER then
			local new_pos = handle_parsing_header(parser, pos, buffer)
			pos = new_pos
		elseif parser.state == M.STATE.WAITING_CODE then
			local new_pos = handle_waiting_code(parser, pos, buffer)
			pos = new_pos
		elseif parser.state == M.STATE.PARSING_CODE then
			local new_pos = handle_parsing_code(parser, pos, buffer)
			pos = new_pos
		else
			break
		end
	end

	-- 如果解析完成，清理缓冲区
	if parser.state == M.STATE.DONE then
		-- 保留已处理位置之后的剩余内容
		if pos <= #parser.buffer then
			local remaining = parser.buffer:sub(pos)
			parser.buffer = remaining
		else
			parser.buffer = ""
		end
		return parser.result
	end

	-- 未完成，保留已处理位置之后的缓冲区
	if pos > 1 then
		parser.buffer = parser.buffer:sub(pos)
	end

	return nil
end

---重置解析器
---@param parser ProtocolParser
function M.reset(parser)
	parser.state = M.STATE.WAITING_BEGIN
	parser.buffer = ""
	parser.header_buffer = ""
	parser.header = {}
	parser.code_lines = {}
	parser.result = nil
	parser.current_line = ""
	parser.last_marker = nil
end

---检查是否完成
---@param parser ProtocolParser
---@return boolean
function M.is_done(parser)
	return parser.state == M.STATE.DONE
end

---快速匹配（非流式，用于完整 chunk）
---@param chunk string
---@return table|nil
function M.match(chunk)
	local parser = M.new()
	M.feed(parser, chunk)
	if M.is_done(parser) then
		return parser.result
	end
	return nil
end
return M
