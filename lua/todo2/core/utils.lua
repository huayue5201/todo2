-- lua/todo2/core/utils.lua
local M = {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- 归档标题工具（供 parser.lua 和 archive.lua 共用）
---------------------------------------------------------------------

-- 固定格式：YYYY-MM
function M.build_archive_title()
	local prefix = config.get("archive_section.title_prefix") or "## Archived"
	local t = os.date("*t")
	return string.format("%s (%04d-%02d)", prefix, t.year, t.month)
end

-- 严格匹配归档标题
function M.is_archive_section_line(line)
	return vim.trim(line) == vim.trim(M.build_archive_title())
end

return M
