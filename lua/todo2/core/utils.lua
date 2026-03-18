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

---------------------------------------------------------------------
-- 获取任务文本（原有方法，保留）
---------------------------------------------------------------------

--- 获取任务文本
--- @param task table 任务对象
--- @param max_len number 最大长度（可选）
--- @return string|nil 任务文本
function M.get_task_text(task, max_len)
	if not task then
		return nil
	end

	local text = task.content or ""
	max_len = max_len or 40

	text = text:gsub("^%s+", ""):gsub("%s+$", "")

	local char_len = vim.str_utfindex(text)
	if char_len <= max_len then
		return text
	end

	local byte_index = vim.str_byteindex(text, max_len - 3, true)
	return text:sub(1, byte_index or #text) .. "..."
end

return M
