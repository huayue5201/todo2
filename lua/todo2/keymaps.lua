-- lua/todo2/keymaps.lua
-- TODO 文件内核心映射（buffer-local），由插件自动提供。
-- 全局 <leader>m* 映射不在此处，由用户按需自行配置。

local M = {}

local file = require("todo2.utils.file")

function M.setup()
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = file.todo_autocmd_pattern(),
		callback = function(args)
			local buf = args.buf
			-- 惰性加载 handlers，避免 setup 时连带加载重模块
			local handlers = require("todo2.handlers")

			vim.keymap.set("n", "q", handlers.ui_close_window, { buffer = buf, desc = "关闭窗口" })
			vim.keymap.set("n", "<C-r>", handlers.ui_refresh, { buffer = buf, desc = "刷新显示" })
			vim.keymap.set("n", "<leader>np", handlers.ui_insert_task, { buffer = buf, desc = "新建任务" })
			vim.keymap.set("n", "<leader>ns", handlers.ui_insert_subtask, { buffer = buf, desc = "新建子任务" })
			vim.keymap.set("n", "<leader>nn", handlers.ui_insert_sibling, { buffer = buf, desc = "新建平级任务" })
			vim.keymap.set({ "v", "x" }, "<CR>", handlers.ui_toggle_selected, { buffer = buf, desc = "批量切换任务状态" })
		end,
	})
end

return M
