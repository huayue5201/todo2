-- lua/todo2/core/archive_utils.lua
local M = {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- 归档标题工具（供 parser.lua 和 archive.lua 共用）
---------------------------------------------------------------------

-- 固定格式：YYYY-MM（用于新建归档段标题）
function M.build_archive_title()
	local prefix = config.get("archive_section.title_prefix") or "## Archived"
	local t = os.date("*t")
	return string.format("%s (%04d-%02d)", prefix, t.year, t.month)
end

-- 严格匹配归档标题：`<prefix>` 或 `<prefix> (YYYY-MM)`，任意月份都算归档段（
-- 旧实现只认当前月，导致跨月后历史归档段不再被识别）。
-- @param line string
-- @return boolean
function M.is_archive_section_line(line)
	if not line then
		return false
	end
	local prefix = vim.trim(config.get("archive_section.title_prefix") or "## Archived")
	local s = vim.trim(line)
	if s == prefix then
		return true
	end
	return s:match("^" .. vim.pesc(prefix) .. "%s*%(%d%d%d%d%-%d%d%)$") ~= nil
end

--- 从归档标题里取出月份 `YYYY-MM`（取不到返回 nil）。
--- @param line string
--- @return string|nil
function M.archive_month(line)
	local y, m = vim.trim(line or ""):match("(%d%d%d%d)%-(%d%d)")
	if not y then
		return nil
	end
	return y .. "-" .. m
end

return M
