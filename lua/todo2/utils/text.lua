-- lua/todo2/utils/text.lua
-- 显示宽度的统一入口。
--
-- 约定：这里所有 `width` 都是 **显示列**（strdisplaywidth），不是字节数、也不是
-- utf8 码点数——CJK / emoji 占 2 列、组合字符占 0 列。需要字节偏移的地方
-- （extmark 列、`nvim_buf_set_text`）不要用这里的返回值。
--
-- 布局代码请统一走这个模块，不要再各自包一层 vim.fn.strdisplaywidth。

local M = {}

--- 字符串的显示宽度（列）。nil / "" → 0
---@param s string|nil
---@return integer
function M.width(s)
	if not s or s == "" then
		return 0
	end
	return vim.fn.strdisplaywidth(s)
end

--- 右侧补空格到目标显示宽度（已够宽则原样返回）
---@param text string
---@param width integer
---@return string
function M.pad_end(text, width)
	local w = M.width(text)
	if w >= width then
		return text
	end
	return text .. string.rep(" ", width - w)
end

--- 左侧补空格到目标显示宽度（已够宽则原样返回）
---@param text string
---@param width integer
---@return string
function M.pad_start(text, width)
	local w = M.width(text)
	if w >= width then
		return text
	end
	return string.rep(" ", width - w) .. text
end

--- 居中（只保证整体不超过 width，右侧不补齐）
---@param text string
---@param width integer
---@return string
function M.center(text, width)
	local pad = math.max(0, width - M.width(text))
	return string.rep(" ", math.floor(pad / 2)) .. text
end

--- 按显示宽度截断，超出时结尾加省略号（省略号本身也计入 width）
---@param text string
---@param width integer
---@param ellipsis? string 默认 "…"
---@return string
function M.truncate(text, width, ellipsis)
	if M.width(text) <= width then
		return text
	end
	ellipsis = ellipsis or "…"
	local room = math.max(0, width - M.width(ellipsis))
	local out = {}
	for _, char in ipairs(vim.fn.split(text, "\\zs")) do
		local next_text = table.concat(out) .. char
		if M.width(next_text) > room then
			break
		end
		out[#out + 1] = char
	end
	return table.concat(out) .. ellipsis
end

--- 行集中最宽一行的显示宽度
---@param lines string[]
---@return integer
function M.max_width(lines)
	local max = 0
	for _, line in ipairs(lines or {}) do
		max = math.max(max, M.width(line))
	end
	return max
end

--- virt_text 片段数组的显示宽度（片段形如 { text, hl }）
---@param chunks table[]
---@return integer
function M.chunks_width(chunks)
	local total = 0
	for _, chunk in ipairs(chunks or {}) do
		total = total + M.width(chunk[1])
	end
	return total
end

return M
