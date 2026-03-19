-- lua/todo2/utils/id.lua
-- 最终版：只支持新格式 TAG:ref:ID，无任何旧格式兼容

local M = {}

--------------------------------------------------
-- 初始化随机种子
--------------------------------------------------
if not M._seeded then
	math.randomseed(vim.loop.hrtime())
	M._seeded = true
end

--------------------------------------------------
-- 常量
--------------------------------------------------

M.REF_SEPARATOR = ":ref:"
M.ID_LENGTH = 6

-- ID 只允许 hex
M.ID_PATTERN = "%x+"

-- TAG 必须是大写字母
M.TAG_PATTERN = "%u+"

-- 新格式：TAG:ref:ID
M.CODE_MARK_PATTERN = "(" .. M.TAG_PATTERN .. ")" .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")"
M.CODE_MARK_PATTERN_NO_CAPTURE = M.TAG_PATTERN .. M.REF_SEPARATOR .. M.ID_PATTERN

--------------------------------------------------
-- ID
--------------------------------------------------

function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

function M.is_valid(id)
	if not id then
		return false
	end
	return id:match("^" .. M.ID_PATTERN .. "$") ~= nil and #id == M.ID_LENGTH
end

--------------------------------------------------
-- code mark（新格式）
--------------------------------------------------

-- ⭐ 唯一输出格式：TAG:ref:ID
function M.format_code_mark(tag, id)
	return tag .. M.REF_SEPARATOR .. id
end

function M.build_code_search_text(tag, id)
	return tag .. M.REF_SEPARATOR .. id
end

function M.get_code_mark_pattern()
	return M.CODE_MARK_PATTERN
end

function M.get_code_mark_pattern_no_capture()
	return M.CODE_MARK_PATTERN_NO_CAPTURE
end

-- 从 code mark 中提取 ID
function M.extract_id_from_code_mark(text)
	if not text then
		return nil
	end
	return text:match(M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")")
end

-- 从 code mark 中提取 tag
function M.extract_tag_from_code_mark(text)
	if not text then
		return nil
	end
	return text:match(M.CODE_MARK_PATTERN)
end

function M.contains_code_mark(text)
	if not text then
		return false
	end
	if not text:find(":ref:", 1, true) then
		return false
	end
	return text:find(M.CODE_MARK_PATTERN_NO_CAPTURE) ~= nil
end

--------------------------------------------------
-- 通用提取
--------------------------------------------------

-- ⭐ 统一入口：只支持新格式
function M.extract_id(text)
	if not text then
		return nil
	end
	return M.extract_id_from_code_mark(text)
end

function M.extract_tag_from_code_line(code_line)
	if not code_line then
		return "TODO"
	end
	return M.extract_tag_from_code_mark(code_line) or "TODO"
end

--------------------------------------------------
-- find position（只支持新格式）
--------------------------------------------------

function M.find_id_position(line, id)
	if not line then
		return nil
	end

	if id then
		local pattern = M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.escape_for_lua_pattern(id) .. ")"
		local tag, found_id = line:match(pattern)

		if tag and found_id then
			local full = tag .. M.REF_SEPARATOR .. found_id
			local s, e = line:find(full, 1, true)
			return s, e, found_id
		end

		return nil
	end

	-- 任意 ID
	local tag, found_id = line:match(M.CODE_MARK_PATTERN)
	if tag and found_id then
		local full = tag .. M.REF_SEPARATOR .. found_id
		local s, e = line:find(full, 1, true)
		return s, e, found_id
	end

	return nil
end

--------------------------------------------------
-- 转义
--------------------------------------------------

function M.escape_for_rg(text)
	if not text then
		return ""
	end
	return text:gsub("([\\.^$|?*+(){}%[%]])", "\\%1")
end

function M.escape_for_lua_pattern(text)
	if not text then
		return ""
	end
	return text:gsub("([%.%*%+%-%?%[%]%^%$])", "%%%1")
end

return M
