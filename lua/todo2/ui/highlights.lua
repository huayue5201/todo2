-- lua/todo2/ui/highlights.lua
local M = {}

-- 简洁的高亮定义，避免冲突
M.highlights = {
	TodoCompleted = { fg = "#888888", gui = "italic,strikethrough" }, -- 已经有删除线
	TodoPending = { fg = "#c0c0c0" },
	TodoCheckboxTodo = { fg = "#888888" },
	TodoCheckboxDone = { fg = "#51cf66" },
	TodoIdIcon = { fg = "#bb9af7" },
	-- 可以添加专门的归档高亮（可选）
	TodoArchived = { fg = "#888888", gui = "strikethrough" },
}

function M.setup()
	for name, hl in pairs(M.highlights) do
		local cmd = string.format("highlight %s guifg=%s", name, hl.fg)
		if hl.gui then
			cmd = cmd .. string.format(" gui=%s", hl.gui)
		end
		vim.cmd(cmd)
	end
end

function M.clear()
	for name in pairs(M.highlights) do
		vim.cmd(string.format("highlight clear %s", name))
	end
end

return M
