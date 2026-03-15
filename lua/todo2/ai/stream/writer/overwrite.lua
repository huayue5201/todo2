-- 覆盖写入策略（原位替换）
local M = {}

local function safe_set_lines(bufnr, start, finish, lines)
	if not bufnr or bufnr == -1 then
		return
	end
	if start > finish then
		finish = start
	end
	lines = lines or {}
	pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, start, finish, false, lines)
	end)
end

function M.write(bufnr, range, lines)
	safe_set_lines(bufnr, range.start_line - 1, range.end_line, lines)
end

return M
