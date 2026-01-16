-- lua/todo2/keymaps.lua
local M = {}

---------------------------------------------------------------------
-- 全局按键声明（原本散落在 init.lua）
---------------------------------------------------------------------
M.global_keymaps = {
	{
		"n",
		"<leader>ta",
		function()
			require("todo2.child").create_child_from_code()
		end,
		"从代码中创建子任务",
	},
	-- 创建链接
	{
		"n",
		"<leader>tA",
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
		function()
			require("todo2.link.viewer").show_project_links_qf()
		end,
		"显示所有双链标记 (QuickFix)",
	},
	{
		"n",
		"<leader>tdl",
		function()
			require("todo2.link.viewer").show_buffer_links_loclist()
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
	-- 智能 <CR>：只有标签行触发 todo2 行为，否则保持默认
	{
		"n",
		"<CR>",
		function()
			local line = vim.fn.getline(".")
			local tag, id = line:match("(%u+):ref:(%w+)")

			-- ⭐ 非 TAG 行 → 默认回车
			if not id then
				return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
			end

			-----------------------------------------------------------------
			-- 1. 获取 TODO 链接
			-----------------------------------------------------------------
			local store = require("todo2.store")
			local link = store.get_todo_link(id, { force_relocate = true })
			if not link then
				vim.notify("未找到 TODO 链接: " .. id, vim.log.levels.ERROR)
				return
			end

			local todo_path = vim.fn.fnamemodify(link.path, ":p")
			local todo_line = link.line or 1

			if vim.fn.filereadable(todo_path) == 0 then
				vim.notify("TODO 文件不存在: " .. todo_path, vim.log.levels.ERROR)
				return
			end

			-----------------------------------------------------------------
			-- 2. 在 TODO buffer 中执行 toggle（不写盘）
			-----------------------------------------------------------------
			local core = require("todo2.core")
			local todo_bufnr = vim.fn.bufnr(todo_path)
			if todo_bufnr == -1 then
				todo_bufnr = vim.fn.bufadd(todo_path)
				vim.fn.bufload(todo_bufnr)
			end

			vim.api.nvim_buf_call(todo_bufnr, function()
				core.toggle_line(todo_bufnr, todo_line)
			end)

			-----------------------------------------------------------------
			-- 3. autosave 写盘（防抖 + 合并）
			-----------------------------------------------------------------
			local autosave = require("todo2.core.autosave")
			autosave.request_save(todo_bufnr)

			-----------------------------------------------------------------
			-- 4. 智能刷新所有相关代码 buffer（父子任务联动）
			-----------------------------------------------------------------
			local renderer = require("todo2.link.renderer")

			-- 获取父任务 + 子任务 ID 列表
			local ids = { id }
			local struct = store.get_task_structure(id)
			if struct and struct.children then
				for _, cid in ipairs(struct.children) do
					table.insert(ids, cid)
				end
			end

			-- 刷新所有 code_link 对应的 buffer（去重）
			local refreshed = {}
			for _, tid in ipairs(ids) do
				local code = store.get_code_link(tid)
				if code then
					local bufnr = vim.fn.bufnr(code.path)
					if bufnr ~= -1 and not refreshed[bufnr] then
						refreshed[bufnr] = true
						renderer.render_code_status(bufnr)
					end
				end
			end
		end,
		"智能切换 TODO 状态（父子任务智能刷新版）",
	},
	-----------------------------------------------------------------
	-- 代码侧 dd：删除代码标记时，同步删除 TODO 行（支持多 {#id} + 可视模式）
	-----------------------------------------------------------------
	-- TODO:ref:7db555
	{
		{ "n", "v" },
		"do",
		function()
			require("todo2.manager").delete_code_link_dT()
		end,
		"删除代码 TAG 并同步 TODO（dT）",
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
