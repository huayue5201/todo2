-- lua/todo2/utils/tags.lua
-- 标签（tags）：多值、与状态（status）正交的任务属性。
--
-- 文件语法（方案 B）：标签段紧跟在 `<status>:<id>` 标记之后，由空格分隔的
-- `#token` 组成，例如：
--     - [ ] todo:ab12cd #fix #backend 修复登录
-- 第一段非 `#` 文本起为任务内容（content 始终保持纯净）。
--
-- 约定：标签统一小写、去重、按字典序排序后存储，保证幂等与稳定 diff。

local M = {}

-- 标签 token 允许的字符集（# 之后）：字母 / 数字 / 下划线 / 连字符 / 斜杠
local TAG_CHARS = "[%w_%-/]+"

--- 校验单个标签 token 是否合法（不含 #）。
---@param token string
---@return boolean
function M.is_valid(token)
	return type(token) == "string" and token:match("^" .. TAG_CHARS .. "$") ~= nil
end

--- 规范化标签列表：去空、去 #、小写、去重、字典序排序。
---@param tags string[]|nil
---@return string[]
function M.normalize(tags)
	if type(tags) ~= "table" then
		return {}
	end
	local seen, out = {}, {}
	for _, raw in ipairs(tags) do
		local t = tostring(raw or ""):gsub("^%s*#", "")
		t = vim.trim(t):lower()
		if M.is_valid(t) and not seen[t] then
			seen[t] = true
			out[#out + 1] = t
		end
	end
	table.sort(out)
	return out
end

--- 从字符串开头切出连续的 `#tag` 序列，返回规范化标签与剩余文本。
--- 标签段之后的第一段非 `#` 文本即任务内容。
---@param text string
---@return string[] tags, string rest
function M.extract(text)
	local raw, rest = {}, text or ""
	while true do
		local tag, tail = rest:match("^%s*#(" .. TAG_CHARS .. ")(.*)$")
		if not tag then
			break
		end
		raw[#raw + 1] = tag
		rest = tail
	end
	return M.normalize(raw), rest
end

--- 生成标签段（带前导空格）；无标签返回 ""。
---@param tags string[]|nil
---@return string
function M.format(tags)
	tags = M.normalize(tags)
	if #tags == 0 then
		return ""
	end
	local parts = {}
	for _, t in ipairs(tags) do
		parts[#parts + 1] = "#" .. t
	end
	return " " .. table.concat(parts, " ")
end

--- 标签列表是否包含某标签（大小写不敏感）。
---@param tags string[]|nil
---@param tag string
---@return boolean
function M.contains(tags, tag)
	if type(tags) ~= "table" or type(tag) ~= "string" then
		return false
	end
	local want = tag:gsub("^%s*#", ""):lower()
	for _, t in ipairs(tags) do
		if t == want then
			return true
		end
	end
	return false
end

return M
