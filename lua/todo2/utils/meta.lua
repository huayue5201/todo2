-- lua/todo2/utils/meta.lua
-- 行尾元数据：任务行的唯一「非正文」语法。
--
--     - [ ] 修登录 @id(ab12cd) @created(1730000000) @due(2026-07-01) #fix
--     ^缩进  ^checkbox  ^正文                              ^元数据块
--
-- 约定：
--   * 元数据是**行尾连续后缀块**，从右往左贪心剥离，遇到未知字段即停；
--     正文里若真的以 `@key(...)` 结尾，用 `\@` 转义（`\` 会使该 token 不被识别）。
--   * 字段顺序固定（见 ORDER），写回时总是规范化成这个顺序。
--   * 只有"写一次就不变"的事实进文件（id / created / start / due / done / archived）
--     + 标签；`updated` 这类每次编辑都变的字段留在 store。
--   * 读取宽松（顺序、多余字段都不报错），写入严格（唯一出口是 M.format）。

local M = {}

local due_utils = require("todo2.utils.due")
local tags_utils = require("todo2.utils.tags")

--- 元数据字段顺序（写回顺序，也是语义分组：身份 → 生命周期 → 排期 → 标签）
M.ORDER = { "id", "created", "start", "due", "done", "archived" }

--- 字段校验/归一化：返回 (是否合法, 归一化值)
local VALIDATORS = {
	id = function(v)
		return v:match("^[0-9a-z]+$") ~= nil, v
	end,
	created = function(v)
		return v:match("^%d+$") ~= nil, tonumber(v)
	end,
	start = function(v)
		return due_utils.is_date(v), v
	end,
	due = function(v)
		return due_utils.is_date(v), v
	end,
	done = function(v)
		return v:match("^%d+$") ~= nil, tonumber(v)
	end,
	archived = function(v)
		return v:match("^%d+$") ~= nil, tonumber(v)
	end,
}

--- 切出最后一个空白分隔的 token；无 token 返回 nil。
---@param text string
---@return string|nil head, string|nil token
local function split_last(text)
	local head, token = text:match("^(.*)%s+(%S+)$")
	if head then
		return head, token
	end
	if text ~= "" and not text:match("%s") then
		return "", text
	end
	return nil, nil
end

--- 解析行尾元数据块。
---@param text string 去掉缩进/checkbox 后的部分
---@return { id?: string, created?: number, start?: string, due?: string, done?: number, archived?: number, tags: string[] } fields
---@return string content 正文（未 trim）
---@return integer|nil block_start 元数据块在 text 内的起点（含前导空白）；无块时为 nil
function M.parse(text)
	local fields = { tags = {} }
	local rest = (text or ""):gsub("%s+$", "")
	local tags = {}
	local block_start = nil

	while true do
		local head, token = split_last(rest)
		if not token then
			break
		end

		local tag = token:match("^#([%w_%-/]+)$")
		if tag then
			tags[#tags + 1] = tag
			block_start = #head + 1
			rest = head
		else
			local name, value = token:match("^@([%a][%w_]*)%(([^%s()]*)%)$")
			local validate = name and VALIDATORS[name]
			if not validate then
				break
			end
			local ok, normalized = validate(value)
			if not ok then
				break
			end
			-- 同一个字段出现多次时，最右（最先被剥离）的生效
			if fields[name] == nil then
				fields[name] = normalized
			end
			block_start = #head + 1
			rest = head
		end
	end

	fields.tags = tags_utils.normalize(tags)
	return fields, rest, block_start
end

--- 生成元数据块（带前导空格）；空字段与非法值被跳过，标签追加在最后。
---@param fields table
---@return string
function M.format(fields)
	fields = fields or {}
	local parts = {}
	for _, name in ipairs(M.ORDER) do
		local value = fields[name]
		local validate = VALIDATORS[name]
		if value ~= nil and validate then
			local ok, normalized = validate(tostring(value))
			if ok then
				parts[#parts + 1] = string.format("@%s(%s)", name, normalized)
			end
		end
	end
	local tag_segment = tags_utils.format(fields.tags)
	if tag_segment ~= "" then
		parts[#parts + 1] = vim.trim(tag_segment)
	end
	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " ")
end

--- 正文末尾是否会被误认成元数据（写入前的告警用）。
---@param content string|nil
---@return boolean
function M.has_trailing_meta(content)
	if not content or content == "" then
		return false
	end
	local _, rest = M.parse(content)
	return rest ~= content
end

return M
