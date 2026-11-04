-- lua/todo2/utils/id.lua
-- 任务 ID：生成、校验、从行内识别。
--
-- ID   ：6 位 base36（0-9a-z），空间 36^6 ≈ 2.2e9；生成时以 store 为准查重。
-- 行内形式：行尾元数据 `@id(xxxxxx)`（见 utils/meta.lua），状态由 checkbox 表达。

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

M.ID_LENGTH = 6

local ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
M.ID_PATTERN = "[0-9a-z]+"

-- 生成时最多重试次数（空间 2.2e9，连撞几乎不可能）
local ID_MAX_ATTEMPTS = 100

--------------------------------------------------
-- 生成与验证
--------------------------------------------------

--- 随机生成一个 ID（纯随机，不查重）
---@return string
function M.random_id()
	local chars = {}
	for i = 1, M.ID_LENGTH do
		local idx = math.random(1, #ID_ALPHABET)
		chars[i] = ID_ALPHABET:sub(idx, idx)
	end
	return table.concat(chars)
end

--- ID 是否已被 store 占用
---@param id string
---@return boolean
local function id_in_use(id)
	local core = require("todo2.store.task.core")
	return core.get_task(id) ~= nil
end

--- 生成一个未被占用的 ID
---@return string
function M.generate_id()
	for _ = 1, ID_MAX_ATTEMPTS do
		local id = M.random_id()
		if not id_in_use(id) then
			return id
		end
	end
	error("todo2: cannot generate a unique ID")
end

--- ID 格式是否合法
---@param id string|nil
---@return boolean
function M.is_valid(id)
	if not id then
		return false
	end
	return id:match("^" .. M.ID_PATTERN .. "$") ~= nil and #id == M.ID_LENGTH
end

--------------------------------------------------
-- 行内识别
--------------------------------------------------

--- 从任意文本中找 `@id(x)`（跳过被 `\` 转义的 token）
---@param text string|nil
---@return string|nil id
function M.extract_id_from_line(text)
	text = text or ""
	local init = 1
	while true do
		local s, e, id = text:find("@id%(([0-9a-z]+)%)", init)
		if not s then
			return nil
		end
		if text:sub(s - 1, s - 1) ~= "\\" then
			return id
		end
		init = e + 1
	end
end

--- 行内是否带任务 ID
---@param text string|nil
---@return boolean
function M.contains_id(text)
	return M.extract_id_from_line(text) ~= nil
end

return M
