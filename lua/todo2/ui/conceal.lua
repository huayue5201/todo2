-- lua/todo2/ui/conceal.lua
local M = {}

local config = require("todo2.config")

function M.setup_conceal_syntax(bufnr)
	local conceal_cfg = config.get_conceal()
	if not conceal_cfg.enable then
		return
	end

	vim.cmd(string.format(
		[[
      buffer %d
      syntax match markdownTodo /\[\s\]/ conceal cchar=%s
      syntax match markdownTodoDone /\[[xX]\]/ conceal cchar=%s
      highlight default link markdownTodo Conceal
      highlight default link markdownTodoDone Conceal
    ]],
		bufnr,
		conceal_cfg.symbols.todo,
		conceal_cfg.symbols.done
	))
end

function M.apply_conceal(bufnr)
	local conceal_cfg = config.get_conceal()
	if not conceal_cfg.enable then
		return
	end

	local win = vim.fn.bufwinid(bufnr)
	if win == -1 then
		return
	end

	vim.api.nvim_set_option_value("conceallevel", conceal_cfg.level, { win = win })
	vim.api.nvim_set_option_value("concealcursor", conceal_cfg.cursor, { win = win })

	M.setup_conceal_syntax(bufnr)
end

function M.toggle_conceal(bufnr)
	local conceal_cfg = config.get_conceal()
	conceal_cfg.enable = not conceal_cfg.enable

	-- 重新应用当前缓冲区
	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		if conceal_cfg.enable then
			M.apply_conceal(bufnr)
		else
			-- 关闭 conceal
			vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
		end
	end

	return conceal_cfg.enable
end

return M
