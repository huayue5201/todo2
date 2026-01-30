--- File: /Users/lijia/todo2/lua/todo2/status/keymap.lua ---
-- lua/todo2/status/keymap.lua
--- @module todo2.status.keymap

-- 只保留两个核心快捷键
vim.keymap.set("n", "<Leader>ts", function()
	-- 直接调用状态模块
	local core_status = require("todo2.core.status")
	core_status.show_status_menu()
end, { desc = "选择任务状态（正常/紧急/等待）" })

vim.keymap.set("n", "<Leader>tc", function()
	-- 直接调用状态模块
	local core_status = require("todo2.core.status")
	core_status.cycle_status()
end, { desc = "循环切换状态（正常→紧急→等待）" })
