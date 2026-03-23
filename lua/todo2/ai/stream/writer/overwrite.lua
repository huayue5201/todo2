-- lua/todo2/ai/stream/writer/overwrite.lua
-- 覆盖写入策略（带进度回调）

local M = {}

--- 写入指定行范围
--- @param bufnr number
--- @param range table { start_line, end_line }
--- @param lines table
--- @param opts table { on_progress = function(current, total) }
--- @return boolean, string
function M.write(bufnr, range, lines, opts)
	opts = opts or {}

	if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "无效的缓冲区"
	end

	local start = range.start_line - 1
	local finish = range.end_line

	if start > finish then
		finish = start
	end

	-- 写入
	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines or {})
	end)

	-- 尝试合并撤销
	pcall(function()
		vim.cmd("silent! undojoin")
	end)

	-- 进度回调
	if opts.on_progress then
		local total = range.end_line - range.start_line + 1
		local current = start + #lines
		opts.on_progress(current, total)
	end

	return true, nil
end

return M
