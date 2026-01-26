-- lua/todo2/keymaps.lua
--- @module todo2.keymaps

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 辅助函数：获取配置（通过主模块）
---------------------------------------------------------------------
local function get_config()
	-- 通过主模块获取配置
	local main = module.get("main")
	if main and main.get_config then
		return main.get_config()
	end
	-- 备用配置
	return {
		link = {
			jump = {
				keep_todo_split_when_jump = true,
				default_todo_window_mode = "float",
				reuse_existing_windows = true,
			},
			preview = {
				enabled = true,
				border = "rounded",
			},
			render = {
				show_status_in_code = true,
			},
		},
		store = {
			auto_relocate = true,
			verbose_logging = false,
			cleanup_days_old = 30,
		},
	}
end

---------------------------------------------------------------------
-- ⭐ 专业版智能 <CR>：只改状态 + 触发事件，不直接刷新
---------------------------------------------------------------------
local function smart_cr()
	-- 通过模块管理器获取依赖
	local store = module.get("store")
	local core = module.get("core")
	local autosave = module.get("core.autosave")

	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")

	-- 非 TAG 行 → 默认回车
	if not id then
		return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
	end

	-- 获取 TODO 链接
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

	-- 在 TODO buffer 中执行 toggle（不写盘）
	local todo_bufnr = vim.fn.bufnr(todo_path)
	if todo_bufnr == -1 then
		todo_bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(todo_bufnr)
	end

	vim.api.nvim_buf_call(todo_bufnr, function()
		core.toggle_line(todo_bufnr, todo_line, { skip_write = true })
	end)

	-- 🟢 只调用 autosave，它会触发事件系统
	autosave.request_save(todo_bufnr)
end
---------------------------------------------------------------------
-- 全局按键声明
---------------------------------------------------------------------
M.global_keymaps = {
	-- 创建子任务
	{
		"n",
		"<leader>ta",
		function()
			module.get("link.child").create_child_from_code()
		end,
		"从代码中创建子任务",
	},

	-- 创建链接
	{
		"n",
		"<leader>tA",
		function()
			module.get("link").create_link()
		end,
		"创建代码→TODO 链接",
	},

	-- 动态跳转
	{
		"n",
		"gj",
		function()
			module.get("link").jump_dynamic()
		end,
		"动态跳转 TODO <-> 代码",
	},

	-- 双链管理
	{
		"n",
		"<leader>tdq",
		function()
			module.get("link.viewer").show_project_links_qf()
		end,
		"显示所有双链标记 (QuickFix)",
	},
	{
		"n",
		"<leader>tdl",
		function()
			module.get("link.viewer").show_buffer_links_loclist()
		end,
		"显示当前缓冲区双链标记 (LocList)",
	},

	-- 孤立修复 / 统计
	{
		"n",
		"<leader>tdr",
		function()
			module.get("manager").fix_orphan_links_in_buffer()
		end,
		"修复当前缓冲区孤立的标记",
	},
	{
		"n",
		"<leader>tdw",
		function()
			module.get("manager").show_stats()
		end,
		"显示双链标记统计",
	},

	-- 悬浮预览
	{
		"n",
		"<leader>tk",
		function()
			local link = module.get("link")
			local line = vim.fn.getline(".")
			if line:match("(%u+):ref:(%w+)") then
				link.preview_todo()
			elseif line:match("{#(%w+)}") then
				link.preview_code()
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
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 浮窗打开",
	},

	{
		"n",
		"<leader>tds",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "horizontal",
					})
				end
			end)
		end,
		"TODO: 水平分割打开",
	},

	{
		"n",
		"<leader>tdv",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "split", 1, {
						enter_insert = false,
						split_direction = "vertical",
					})
				end
			end)
		end,
		"TODO: 垂直分割打开",
	},

	{
		"n",
		"<leader>tde",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
				end
			end)
		end,
		"TODO: 编辑模式打开",
	},

	{
		"n",
		"<leader>tdn",
		function()
			module.get("ui").create_todo_file()
		end,
		"TODO: 创建文件",
	},

	{
		"n",
		"<leader>tdd",
		function()
			local ui = module.get("ui")
			ui.select_todo_file("current", function(choice)
				if choice then
					ui.delete_todo_file(choice.path)
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
		function()
			local config = get_config()
			local store = module.get("store")
			local days = (config.store and config.store.cleanup_days_old) or 30
			local cleaned = store.cleanup_expired(days)
			if cleaned then
				vim.notify("清理了 " .. cleaned .. " 条过期数据")
			end
		end,
		"清理过期存储数据",
	},

	{
		"n",
		"<leader>tdy",
		function()
			local config = get_config()
			local store = module.get("store")
			local results = store.validate_all_links({
				verbose = config.store.verbose_logging,
				force = false,
			})
			if results and results.summary then
				vim.notify(results.summary)
			end
		end,
		"验证所有链接",
	},

	-----------------------------------------------------------------
	-- ⭐ 智能 <CR>（事件驱动版）
	-----------------------------------------------------------------
	{
		"n",
		"<CR>",
		smart_cr,
		"智能切换 TODO 状态（事件驱动刷新）",
	},

	-----------------------------------------------------------------
	-- 删除代码 TAG 并同步 TODO
	-----------------------------------------------------------------
	{
		{ "n", "v" },
		"<leader>cd",
		function()
			module.get("manager").delete_code_link()
		end,
		"删除代码 TAG 并同步 TODO（dT）",
	},
}

---------------------------------------------------------------------
-- UI 按键声明
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
	-- 保持兼容性，但内部使用模块管理器
	for _, map in ipairs(M.global_keymaps) do
		local mode, lhs, fn, desc = map[1], map[2], map[3], map[4]
		vim.keymap.set(mode, lhs, fn, { desc = desc })
	end
end

return M
