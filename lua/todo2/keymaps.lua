-- lua/todo2/keymaps.lua
-- TODO 文件内核心映射（buffer-local），由插件自动提供。
-- 全局 <leader>m* 映射不在此处，由用户按需自行配置。
--
-- 这里只放「只在 TODO 文件里才有意义」的动作；通用的智能键（<CR>/<BS>/<S-Tab>）
-- 由 plugin/todo2.lua 按普通文件 buffer 统一挂载，查看窗口的 `q` 由窗口自己挂。

local M = {}

local file = require("todo2.utils.file")

function M.setup()
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = file.todo_autocmd_pattern(),
		callback = function(args)
			local buf = args.buf
			-- 惰性加载 handlers，避免 setup 时连带加载重模块
			local handlers = require("todo2.handlers")

			-- 新增任务统一用 <localleader>（buffer 局部，避免抢占全局 <leader>n 笔记组）
			vim.keymap.set("n", "<localleader>n", handlers.ui_insert_task, { buffer = buf, desc = "新任务" })
			vim.keymap.set("n", "<localleader>nc", handlers.ui_insert_subtask, { buffer = buf, desc = "新子任务" })
			vim.keymap.set("n", "<localleader>ns", handlers.ui_insert_sibling, { buffer = buf, desc = "新同级任务" })
			vim.keymap.set(
				"v",
				"<CR>",
				handlers.ui_toggle_selected,
				{ buffer = buf, desc = "Toggle selected tasks' status" }
			)
		end,
	})
end

return M
