-- lua/todo2/keymaps.lua
local M = {}

---------------------------------------------------------------------
-- 全局按键声明（原本散落在 init.lua）
---------------------------------------------------------------------
M.global_keymaps = {
	-- 创建链接
	{
		"n",
		"<leader>tda",
		function(mod)
			mod.link.create_link()
		end,
		"创建代码→TODO 链接",
	},

	-- 动态跳转
	{
		"n",
		"gj",
		function(mod)
			mod.link.jump_dynamic()
		end,
		"动态跳转 TODO <-> 代码",
	},

	-- 双链管理
	{
		"n",
		"<leader>tdq",
		function(mod)
			mod.manager.show_project_links_qf()
		end,
		"显示所有双链标记 (QuickFix)",
	},
	{
		"n",
		"<leader>tdl",
		function(mod)
			mod.manager.show_buffer_links_loclist()
		end,
		"显示当前缓冲区双链标记 (LocList)",
	},
	{
		"n",
		"<leader>tdr",
		function(mod)
			mod.manager.fix_orphan_links_in_buffer()
		end,
		"修复当前缓冲区孤立的标记",
	},
	{
		"n",
		"<leader>tdw",
		function(mod)
			mod.manager.show_stats()
		end,
		"显示双链标记统计",
	},

	-- 悬浮预览
	{
		"n",
		"<leader>tk",
		function(mod)
			local line = vim.fn.getline(".")
			if line:match("(%u+):ref:(%w+)") then
				mod.link.preview_todo()
			elseif line:match("{#(%w+)}") then
				mod.link.preview_code()
			else
				vim.lsp.buf.hover()
			end
		end,
		"预览 TODO 或代码",
	},

	-----------------------------------------------------------------
	-- TODO 文件管理
	-----------------------------------------------------------------
	{
		"n",
		"<leader>tdf",
		function(mod)
			mod.ui.select_todo_file("current", function(choice)
				if choice then
					mod.ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 浮窗打开",
	},

	{
		"n",
		"<leader>tds",
		function(mod)
			mod.ui.select_todo_file("current", function(choice)
				if choice then
					mod.ui.open_todo_file(
						choice.path,
						"split",
						1,
						{ enter_insert = false, split_direction = "horizontal" }
					)
				end
			end)
		end,
		"TODO: 水平分割打开",
	},
	{
		"n",
		"<leader>tdv",
		function(mod)
			mod.ui.select_todo_file("current", function(choice)
				if choice then
					mod.ui.open_todo_file(
						choice.path,
						"split",
						1,
						{ enter_insert = false, split_direction = "vertical" }
					)
				end
			end)
		end,
		"TODO: 垂直分割打开",
	},

	{
		"n",
		"<leader>tde",
		function(mod)
			mod.ui.select_todo_file("current", function(choice)
				if choice then
					mod.ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 编辑模式打开",
	},

	{
		"n",
		"<leader>tdn",
		function(mod)
			mod.ui.create_todo_file()
		end,
		"TODO: 创建文件",
	},
	{
		"n",
		"<leader>tdd",
		function(mod)
			mod.ui.select_todo_file("current", function(choice)
				if choice then
					mod.ui.delete_todo_file(choice.path)
				end
			end)
		end,
		"TODO: 删除文件",
	},

	-----------------------------------------------------------------
	-- 存储维护
	-----------------------------------------------------------------
	{
		"n",
		"<leader>tdc",
		function(mod)
			local days = (mod.config.store and mod.config.store.cleanup_days_old) or 30
			local cleaned = mod.store.cleanup(days)
			if cleaned then
				vim.notify("清理了 " .. cleaned .. " 条过期数据")
			end
		end,
		"清理过期存储数据",
	},

	{
		"n",
		"<leader>tdy",
		function(mod)
			local results = mod.store.validate_all_links({
				verbose = mod.config.store.verbose_logging,
				force = false,
			})
			if results and results.summary then
				vim.notify(results.summary)
			end
		end,
		"验证所有链接",
	},
}

---------------------------------------------------------------------
-- UI 按键声明（原本在 constants.lua）
-- ui/keymaps.lua 将只保留 handler，不再声明按键
---------------------------------------------------------------------
M.ui_keymaps = {
	close = { "n", "q", "关闭窗口" },
	refresh = { "n", "<C-r>", "刷新显示" },
	toggle = { "n", "<cr>", "切换任务状态" },
	toggle_insert = { "i", "<C-CR>", "切换任务状态" },
	toggle_selected = { { "v", "x" }, "<cr>", "批量切换任务状态" },
	new_task = { "n", "<leader>nt", "新建任务" },
	new_subtask = { "n", "<leader>nT", "新建子任务" },
	new_sibling = { "n", "<leader>ns", "新建平级任务" },
}

---------------------------------------------------------------------
-- 注册全局按键
---------------------------------------------------------------------
function M.setup_global(modules)
	for _, map in ipairs(M.global_keymaps) do
		local mode, lhs, fn, desc = map[1], map[2], map[3], map[4]
		vim.keymap.set(mode, lhs, function()
			fn(modules)
		end, { desc = desc })
	end
end

return M
