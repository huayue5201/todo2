local M = {}

function M.write(bufnr, range, lines)
	vim.api.nvim_buf_set_lines(bufnr, range.start_line, range.start_line, false, lines)
end

return M
