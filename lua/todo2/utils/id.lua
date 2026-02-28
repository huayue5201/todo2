-- lua/todo2/utils/id.lua
--- @module todo2.utils.id
--- @brief ID处理中心 - 所有ID相关的格式、提取、验证都集中在此

local M = {}
-- NOTE:ref:a589d4

--- ==================================================
--- 配置常量
--- ==================================================

--- ID分隔符
M.REF_SEPARATOR = ":ref:"

--- ID长度（十六进制字符数）
M.ID_LENGTH = 6

--- ID正则模式 - 使用 %w+ 以匹配原代码行为
M.ID_PATTERN = "%w+"

--- 标签正则模式 - 匹配大写字母数字组合，完全对齐原代码的 "(%u+):ref:%w+"
M.TAG_PATTERN = "%u+"

--- 代码标记正则（带捕获）- 完全对齐原代码的 "(%u+):ref:%w+"
M.CODE_MARK_PATTERN = "(" .. M.TAG_PATTERN .. ")" .. M.REF_SEPARATOR .. M.ID_PATTERN

--- 代码标记正则（不带捕获）- 完全对齐原代码
M.CODE_MARK_PATTERN_NO_CAPTURE = M.TAG_PATTERN .. M.REF_SEPARATOR .. M.ID_PATTERN

--- TODO锚点正则（带捕获）- 完全对齐原代码的 "({#%w+})"
M.TODO_ANCHOR_PATTERN = "{#(" .. M.ID_PATTERN .. ")}"

--- TODO锚点正则（不带捕获）- 完全对齐原代码
M.TODO_ANCHOR_PATTERN_NO_CAPTURE = "{#" .. M.ID_PATTERN .. "}"

--- ==================================================
--- 核心方法
--- ==================================================

--- 生成唯一ID
--- @return string 6位十六进制ID
function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

--- 验证ID格式
--- @param id string
--- @return boolean
function M.is_valid(id)
	if not id then
		return false
	end
	-- 验证是否为6位字母数字
	return id:match("^%w+$") ~= nil and #id == M.ID_LENGTH
end

--- 获取ID长度
--- @return number
function M.get_id_length()
	return M.ID_LENGTH
end

--- 获取ID正则模式
--- @return string
function M.get_id_pattern()
	return M.ID_PATTERN
end

--- ==================================================
--- 代码标记相关
--- ==================================================

--- 格式化代码标记
--- @param tag string 标签（如 TODO, FIX）
--- @param id string ID
--- @return string 格式如 "TODO:ref:1a2b3c"
function M.format_code_mark(tag, id)
	return tag .. M.REF_SEPARATOR .. id
end

--- 构建代码标记搜索模式（纯文本）
--- @param tag string 标签
--- @param id string ID
--- @return string 纯文本模式
function M.build_code_search_text(tag, id)
	return tag .. M.REF_SEPARATOR .. id
end

--- 获取代码标记正则（带捕获）
--- @return string
function M.get_code_mark_pattern()
	return M.CODE_MARK_PATTERN
end

--- 获取代码标记正则（不带捕获）
--- @return string
function M.get_code_mark_pattern_no_capture()
	return M.CODE_MARK_PATTERN_NO_CAPTURE
end

--- 从代码标记中提取ID - 完全对齐原代码行为
--- @param text string 包含代码标记的文本
--- @return string|nil ID
function M.extract_id_from_code_mark(text)
	if not text then
		return nil
	end
	-- 使用完整模式匹配，提取ID部分
	local full_pattern = M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")"
	return text:match(full_pattern)
end

--- 从代码标记中提取标签 - 完全对齐原代码的 "(%u+):ref:%w+"
--- @param text string 包含代码标记的文本
--- @return string|nil 标签
function M.extract_tag_from_code_mark(text)
	if not text then
		return nil
	end
	return text:match(M.CODE_MARK_PATTERN)
end

--- 检查文本是否包含代码标记
--- @param text string
--- @return boolean
function M.contains_code_mark(text)
	if not text then
		return false
	end
	return text:find(M.CODE_MARK_PATTERN_NO_CAPTURE) ~= nil
end

--- ==================================================
--- TODO锚点相关
--- ==================================================

--- 格式化TODO锚点 - 完全对齐原代码的 "{#1a2b3c}"
--- @param id string ID
--- @return string 格式如 "{#1a2b3c}"
function M.format_todo_anchor(id)
	return "{#" .. id .. "}"
end

--- 构建TODO锚点搜索模式（纯文本）
--- @param id string ID
--- @return string 纯文本模式
function M.build_todo_search_text(id)
	return "{#" .. id .. "}"
end

--- 获取TODO锚点正则（带捕获）
--- @return string
function M.get_todo_anchor_pattern()
	return M.TODO_ANCHOR_PATTERN
end

--- 获取TODO锚点正则（不带捕获）
--- @return string
function M.get_todo_anchor_pattern_no_capture()
	return M.TODO_ANCHOR_PATTERN_NO_CAPTURE
end

--- 从TODO锚点中提取ID - 完全对齐原代码的 line:match("({#%w+})")
--- @param text string 包含TODO锚点的文本
--- @return string|nil ID
function M.extract_id_from_todo_anchor(text)
	if not text then
		return nil
	end
	return text:match(M.TODO_ANCHOR_PATTERN)
end

--- 检查文本是否包含TODO锚点 - 完全对齐原代码
--- @param text string
--- @return boolean
function M.contains_todo_anchor(text)
	if not text then
		return false
	end
	return text:find(M.TODO_ANCHOR_PATTERN_NO_CAPTURE) ~= nil
end

--- ==================================================
--- 通用方法
--- ==================================================

--- 通用提取ID（自动识别格式）
--- @param text string 包含标记的文本
--- @return string|nil ID
function M.extract_id(text)
	if not text then
		return nil
	end
	-- 先尝试代码标记
	local id = M.extract_id_from_code_mark(text)
	if id then
		return id
	end
	-- 再尝试TODO锚点
	return M.extract_id_from_todo_anchor(text)
end

--- 通用检查是否包含标记
--- @param text string
--- @return boolean
function M.contains_mark(text)
	if not text then
		return false
	end
	return M.contains_code_mark(text) or M.contains_todo_anchor(text)
end

--- 构建组合搜索模式（用于rg等工具）
--- @param id string ID
--- @return string 组合模式
function M.build_combined_search_pattern(id)
	return string.format("{%s}|%s%s", id, M.REF_SEPARATOR, id)
end

--- ==================================================
--- 转义方法（用于搜索工具）
--- ==================================================

--- 转义rg特殊字符
--- @param text string 原始文本
--- @return string 转义后的文本
function M.escape_for_rg(text)
	if not text then
		return ""
	end
	-- 转义 {}[]()等特殊字符
	return text:gsub("([{}()%[%]])", "\\%1")
end

--- 转义Lua模式特殊字符
--- @param text string 原始文本
--- @return string 转义后的文本
function M.escape_for_lua_pattern(text)
	if not text then
		return ""
	end
	-- 转义 Lua 模式中的特殊字符
	return text:gsub("([%.%*%+%-%?%[%]%^%$])", "%%%1")
end

--- ==================================================
--- 兼容原有函数
--- ==================================================

--- 从代码行提取标签（兼容原 extract_tag_from_code_line）
--- @param code_line string 代码行
--- @return string 标签名，默认返回 "TODO"
function M.extract_tag_from_code_line(code_line)
	if not code_line then
		return "TODO"
	end
	local tag = M.extract_tag_from_code_mark(code_line)
	return tag or "TODO"
end

--- ==================================================
--- 辅助方法
--- ==================================================

--- 获取ID在行中的位置 - 完全对齐原代码行为
--- @param line string 行内容
--- @param id string ID（可选，如果不提供则查找任何ID）
--- @return number|nil start_pos, number|nil end_pos, string|nil found_id
function M.find_id_position(line, id)
	if not line then
		return nil
	end

	if id then
		-- 查找指定ID
		local code_pattern = M.escape_for_lua_pattern(M.REF_SEPARATOR .. id)
		local start_pos, end_pos = line:find(code_pattern)
		if start_pos then
			-- 找到分隔符位置，往前找标签
			local line_start = line:sub(1, start_pos - 1)
			local tag = line_start:match("(%u+)$")
			if tag then
				return start_pos - #tag, end_pos, id
			end
			return start_pos, end_pos, id
		end

		local todo_pattern = M.escape_for_lua_pattern(M.format_todo_anchor(id))
		start_pos, end_pos = line:find(todo_pattern)
		if start_pos then
			return start_pos, end_pos, id
		end
	else
		-- 查找任意ID - 优先匹配代码标记
		local tag, id = line:match(M.CODE_MARK_PATTERN)
		if tag and id then
			local pattern = tag .. M.REF_SEPARATOR .. id
			local start_pos, end_pos = line:find(pattern)
			return start_pos, end_pos, id
		end

		-- 再匹配TODO锚点
		local id = line:match(M.TODO_ANCHOR_PATTERN)
		if id then
			local pattern = "{#" .. id .. "}"
			local start_pos, end_pos = line:find(pattern)
			return start_pos, end_pos, id
		end
	end

	return nil
end

return M
