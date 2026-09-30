-- lua/todo2/utils/id.lua
-- 任务 ID 生成 + TODO 文件标记
--
-- ID   ：6 位 base36（0-9a-z），空间 36^6 ≈ 2.2e9；生成时以 store 为准查重。
-- 标记 ：<status>:<id>，前缀即任务状态 key —— 活跃状态用配置的 status.cycle label，
--        终态用 completed / archived。

local M = {}

local types = require("todo2.store.types")

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
-- 状态模块懒加载（避免模块加载期循环依赖）
--------------------------------------------------
local status_mod -- nil=未加载, false=加载失败
local function status_domain()
	if status_mod == nil then
		local ok, mod = pcall(require, "todo2.core.status")
		status_mod = ok and mod or false
	end
	return status_mod or nil
end

--- 所有合法前缀：终态 + 用户配置的循环状态 label
---@return string[]
local function known_prefixes()
	local list = { types.STATUS.COMPLETED, types.STATUS.ARCHIVED }
	local sd = status_domain()
	if sd then
		for _, def in ipairs(sd.get_cycle()) do
			list[#list + 1] = def.label
		end
	end
	return list
end

--- 状态 → 标记前缀（含冒号）
---@param status string|nil 任务状态；nil 或未知时回退到默认循环状态
---@return string
function M.prefix_for(status)
	if status == types.STATUS.COMPLETED or status == types.STATUS.ARCHIVED then
		return status .. ":"
	end

	local sd = status_domain()
	local cycle = sd and sd.get_cycle() or {}
	for _, def in ipairs(cycle) do
		if def.label == status then
			return status .. ":"
		end
	end

	-- 回退到默认（第一个）循环状态
	if cycle[1] then
		return cycle[1].label .. ":"
	end

	return "todo:"
end

--------------------------------------------------
-- ID 生成与验证
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
	error("todo2: 无法生成唯一 ID")
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
-- TODO 文件标记格式化
--------------------------------------------------

--- 格式化任务行标记：<status>:ID
---@param id string
---@param status string|nil 任务状态
---@return string
function M.format_mark(id, status)
	return M.prefix_for(status) .. id
end

--- 从任务行提取标记，返回 id 与完整 mark 文本。
--- mark 必须紧跟行首或空白（checkbox 后的空格）。
--- 前缀在 known_prefixes() 中枚举，因此旧格式 "id:" 不再被识别。
---@param line string
---@return string|nil id, string|nil mark
function M.extract_mark(line)
	if not line then
		return nil
	end
	for _, prefix in ipairs(known_prefixes()) do
		local esc = vim.pesc(prefix)
		local mark = line:match("^(" .. esc .. ":" .. M.ID_PATTERN .. ")")
			or line:match("%s(" .. esc .. ":" .. M.ID_PATTERN .. ")")
		if mark then
			return mark:match(":(" .. M.ID_PATTERN .. ")$"), mark
		end
	end
	return nil
end

--- 从任务行提取 ID。
---@param line string
---@return string|nil
function M.extract_id_from_line(line)
	local id = M.extract_mark(line)
	return id
end

--- 检查行是否包含任务标记。
---@param line string
---@return boolean
function M.contains_mark(line)
	if not line then
		return false
	end
	for _, prefix in ipairs(known_prefixes()) do
		local pat = vim.pesc(prefix) .. ":" .. M.ID_PATTERN
		if line:find("^" .. pat) or line:find("%s" .. pat) then
			return true
		end
	end
	return false
end

return M
