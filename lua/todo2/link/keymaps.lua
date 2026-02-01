-- lua/todo2/link/keymaps.lua
--- @module todo2.link.keymaps
--- @brief 双链相关的按键映射模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 辅助函数：获取配置
---------------------------------------------------------------------
local function get_config()
	local main = module.get("main")
	if main and main.get_config then
		return main.get_config()
	end
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
-- ⭐ 智能 <CR>：只改状态 + 触发事件，不直接刷新
---------------------------------------------------------------------
local function smart_cr()
	local store = module.get("store")
	local state_manager = module.get("core.state_manager") -- ✅ 修正模块路径
	local autosave = module.get("core.autosave")

	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")

	if not id then
		return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
	end

	local link = store.get_todo_link(id, { force_relocate = true })
	if not link then
		local ui = module.get("ui")
		if ui and ui.show_notification then
			ui.show_notification("未找到 TODO 链接: " .. id, vim.log.levels.ERROR)
		end
		return
	end

	local todo_path = vim.fn.fnamemodify(link.path, ":p")
	local todo_line = link.line or 1

	if vim.fn.filereadable(todo_path) == 0 then
		local ui = module.get("ui")
		if ui and ui.show_notification then
			ui.show_notification("TODO 文件不存在: " .. todo_path, vim.log.levels.ERROR)
		end
		return
	end

	local todo_bufnr = vim.fn.bufnr(todo_path)
	if todo_bufnr == -1 then
		todo_bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(todo_bufnr)
	end

	vim.api.nvim_buf_call(todo_bufnr, function()
		-- ⭐ 直接调用 toggle_line，它会处理保存和事件触发
		local success, is_done = state_manager.toggle_line(todo_bufnr, todo_line)
		if success then
			-- 不再需要手动调用 autosave，因为 toggle_line 已经调用了
		end
	end)
end

---------------------------------------------------------------------
-- ⭐ 智能删除：只在标记行上删除，非标记行使用默认删除
---------------------------------------------------------------------
local function smart_delete()
	local line = vim.fn.getline(".")

	-- 检查当前行是否有标记
	local has_code_mark = line:match("[A-Z][A-Z0-9_]+:ref:%w+")
	local has_todo_mark = line:match("{#%w+}")

	-- 如果有标记，调用删除功能
	if has_code_mark or has_todo_mark then
		module.get("link.deleter").delete_code_link()
	else
		return
	end
end

---------------------------------------------------------------------
-- 双链相关的全局按键声明
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

	-- 孤立修复
	{
		"n",
		"<leader>tdr",
		function()
			module.get("link.cleaner").cleanup_orphan_links_in_buffer()
		end,
		"修复当前缓冲区孤立的标记",
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
				-- 通过UI模块显示通知
				local ui = module.get("ui")
				if ui and ui.show_notification then
					ui.show_notification("清理了 " .. cleaned .. " 条过期数据")
				else
					vim.notify("清理了 " .. cleaned .. " 条过期数据")
				end
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
				-- 通过UI模块显示通知
				local ui = module.get("ui")
				if ui and ui.show_notification then
					ui.show_notification(results.summary)
				else
					vim.notify(results.summary)
				end
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
	-- ⭐ 智能删除：只在标记行上删除，非标记行使用默认删除
	-----------------------------------------------------------------
	{
		{ "n", "v" },
		"<c-cr>",
		smart_delete,
		"智能删除：标记行删除双链，非标记行正常删除",
	},
}

---------------------------------------------------------------------
-- 注册双链相关的全局按键
---------------------------------------------------------------------
function M.setup_global_keymaps()
	for _, map in ipairs(M.global_keymaps) do
		local mode, lhs, fn, desc = map[1], map[2], map[3], map[4]
		vim.keymap.set(mode, lhs, fn, { desc = desc })
	end
end

return M
