-- lua/todo2/ui/conceal.lua
local M = {}

local config = require("todo2.config")

function M.setup_conceal_syntax(bufnr)
	-- 修改点：使用新的配置访问方式
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return
	end

	local conceal_symbols = config.get("conceal_symbols")
	if not conceal_symbols then
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
		conceal_symbols.todo,
		conceal_symbols.done
	))
end

function M.apply_conceal(bufnr)
	-- 修改点：使用新的配置访问方式
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return
	end

	local win = vim.fn.bufwinid(bufnr)
	if win == -1 then
		return
	end

	-- 修改点：使用硬编码的默认值，因为新配置中没有 level 和 cursor 配置
	local conceal_level = 2 -- 默认值
	local conceal_cursor = "nvic" -- 默认值

	vim.api.nvim_set_option_value("conceallevel", conceal_level, { win = win })
	vim.api.nvim_set_option_value("concealcursor", conceal_cursor, { win = win })

	M.setup_conceal_syntax(bufnr)
end

function M.toggle_conceal(bufnr)
	-- 修改点：使用新的配置访问方式
	local current_enable = config.get("conceal_enable")
	local new_enable = not current_enable

	-- 更新配置
	config.update("conceal_enable", new_enable)

	-- 重新应用当前缓冲区
	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		if new_enable then
			M.apply_conceal(bufnr)
		else
			-- 关闭 conceal
			vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
		end
	end

	return new_enable
end

return M
