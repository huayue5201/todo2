-- lua/todo2/ui/scratch.lua
-- 只读 scratch 浮窗：在右侧开一个一次性 buffer 展示文本，供 :TodoContext! / :TodoGitBlame 等复用。

local M = {}

--- 在右侧打开一个只读 scratch buffer 展示文本。
---@param text string
---@param filetype? string 形如 markdown / json / git；缺省 markdown
---@return integer buf
function M.open(text, filetype)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.split(text, "\n", true))
	vim.api.nvim_set_option_value("filetype", filetype or "markdown", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.cmd("botright vsplit")
	vim.api.nvim_win_set_buf(0, buf)
	return buf
end

return M
