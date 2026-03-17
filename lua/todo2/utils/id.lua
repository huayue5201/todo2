-- lua/todo2/utils/id.lua
-- 升级版（完全兼容 + 修复关键问题）

local M = {}

--------------------------------------------------
-- 初始化随机种子（避免重复ID）
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

-- ⚠️ 兼容旧行为：仍允许 %w，但内部尽量收敛 hex
M.ID_PATTERN = "%w+"

M.TAG_PATTERN = "%u+"

M.CODE_MARK_PATTERN = "(" .. M.TAG_PATTERN .. ")" .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")"
M.CODE_MARK_PATTERN_NO_CAPTURE = M.TAG_PATTERN .. M.REF_SEPARATOR .. M.ID_PATTERN

M.TODO_ANCHOR_PATTERN = "{#(" .. M.ID_PATTERN .. ")}"
M.TODO_ANCHOR_PATTERN_NO_CAPTURE = "{#" .. M.ID_PATTERN .. "}"

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
	return id:match("^%w+$") ~= nil and #id == M.ID_LENGTH
end

function M.get_id_length()
	return M.ID_LENGTH
end

function M.get_id_pattern()
	return M.ID_PATTERN
end

--------------------------------------------------
-- code mark
--------------------------------------------------

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

-- ✔ 修复：强制截断长度（兼容旧数据）
local function normalize_id(id)
	if not id then
		return nil
	end
	if #id > M.ID_LENGTH then
		return id:sub(1, M.ID_LENGTH)
	end
	return id
end

function M.extract_id_from_code_mark(text)
	if not text then
		return nil
	end

	local id = text:match(M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")")
	return normalize_id(id)
end

function M.extract_tag_from_code_mark(text)
	if not text then
		return nil
	end
	local tag = text:match(M.CODE_MARK_PATTERN)
	return tag
end

function M.contains_code_mark(text)
	if not text then
		return false
	end
	-- ⚡ 快速路径优化
	if not text:find(":ref:", 1, true) then
		return false
	end
	return text:find(M.CODE_MARK_PATTERN_NO_CAPTURE) ~= nil
end

--------------------------------------------------
-- todo anchor
--------------------------------------------------

function M.format_todo_anchor(id)
	return "{#" .. id .. "}"
end

function M.build_todo_search_text(id)
	return "{#" .. id .. "}"
end

function M.get_todo_anchor_pattern()
	return M.TODO_ANCHOR_PATTERN
end

function M.get_todo_anchor_pattern_no_capture()
	return M.TODO_ANCHOR_PATTERN_NO_CAPTURE
end

function M.extract_id_from_todo_anchor(text)
	if not text then
		return nil
	end
	local id = text:match(M.TODO_ANCHOR_PATTERN)
	return normalize_id(id)
end

function M.contains_todo_anchor(text)
	if not text then
		return false
	end
	-- ⚡ 快速路径
	if not text:find("{#", 1, true) then
		return false
	end
	return text:find(M.TODO_ANCHOR_PATTERN_NO_CAPTURE) ~= nil
end

--------------------------------------------------
-- 通用
--------------------------------------------------

function M.extract_id(text)
	if not text then
		return nil
	end

	local id = M.extract_id_from_code_mark(text)
	if id then
		return id
	end

	return M.extract_id_from_todo_anchor(text)
end

function M.contains_mark(text)
	if not text then
		return false
	end

	-- ⚡ 快速路径（避免正则）
	if not text:find(":ref:", 1, true) and not text:find("{#", 1, true) then
		return false
	end

	return M.contains_code_mark(text) or M.contains_todo_anchor(text)
end

function M.build_combined_search_pattern(id)
	-- ✔ 修复：正确转义 rg
	return string.format("\\{#%s\\}|%s%s", id, M.REF_SEPARATOR, id)
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

--------------------------------------------------
-- 兼容
--------------------------------------------------

function M.extract_tag_from_code_line(code_line)
	if not code_line then
		return "TODO"
	end
	local tag = M.extract_tag_from_code_mark(code_line)
	return tag or "TODO"
end

--------------------------------------------------
-- find position（✔ 修复核心 bug）
--------------------------------------------------

function M.find_id_position(line, id)
	if not line then
		return nil
	end

	-- 指定 ID
	if id then
		-- code mark
		local pattern = M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.escape_for_lua_pattern(id) .. ")"
		local tag, found_id = line:match(pattern)

		if tag and found_id then
			local full = tag .. M.REF_SEPARATOR .. found_id
			local s, e = line:find(full, 1, true)
			return s, e, found_id
		end

		-- todo anchor
		local anchor = M.format_todo_anchor(id)
		local s, e = line:find(anchor, 1, true)
		if s then
			return s, e, id
		end

		return nil
	end

	-- 任意 ID（✔ 修复：正确捕获 id）
	local tag, found_id = line:match(M.CODE_MARK_PATTERN)
	if tag and found_id then
		local full = tag .. M.REF_SEPARATOR .. found_id
		local s, e = line:find(full, 1, true)
		return s, e, found_id
	end

	if found_id then
		local full = "{#" .. found_id .. "}"
		local s, e = line:find(full, 1, true)
		return s, e, found_id
	end

	return nil
end

return M
