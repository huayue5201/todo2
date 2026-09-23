-- lua/todo2/utils/id.lua
-- 精简版：只保留 ID 生成和 TODO 文件标记功能

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

-- TODO 文件标记格式：TAG:ref:ID
M.TODO_MARK_PATTERN = "(" .. M.TAG_PATTERN .. ")" .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")"

--------------------------------------------------
-- ID 生成与验证
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
-- TODO 文件标记格式化
--------------------------------------------------

---格式化任务行标记：TAG:ref:ID
---@param tag string
---@param id string
---@return string
function M.format_mark(tag, id)
	return tag .. M.REF_SEPARATOR .. id
end

---从任务行提取 ID
---@param line string
---@return string|nil
function M.extract_id_from_line(line)
	if not line then
		return nil
	end
	return line:match(M.TAG_PATTERN .. M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")")
end

---提取行中所有 ID（匹配所有 :ref:ID 出现）
---@param line string
---@return string[]
function M.extract_all_ids(line)
	local ids = {}
	if not line then
		return ids
	end
	for id in line:gmatch(M.REF_SEPARATOR .. "(" .. M.ID_PATTERN .. ")") do
		ids[#ids + 1] = id
	end
	return ids
end

---从任务行提取 TAG
---@param line string
---@return string|nil
function M.extract_tag_from_line(line)
	if not line then
		return nil
	end
	return line:match(M.TODO_MARK_PATTERN)
end

---检查行是否包含任务标记
---@param line string
---@return boolean
function M.contains_mark(line)
	if not line then
		return false
	end
	if not line:find(":ref:", 1, true) then
		return false
	end
	return line:find(M.TAG_PATTERN .. M.REF_SEPARATOR .. M.ID_PATTERN) ~= nil
end

return M
