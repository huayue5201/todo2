-- File: plugin/todo2.lua
-- 轻量入口：只注册惰性触发器（命令 / 全局键 / TODO 文件检测）。
-- 真正的初始化（require("todo2").setup()）在首次需要时执行，
-- 懒加载责任在插件端，不依赖插件管理器或用户手动 setup。

if vim.g.loaded_todo2 then
	return
end
vim.g.loaded_todo2 = 1

---------------------------------------------------------------------
-- 用户配置（在 init.lua 中设置 vim.g.todo2_config，供惰性 setup 使用）
---------------------------------------------------------------------
vim.g.todo2_config = vim.g.todo2_config or {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- 惰性初始化：首次触发时执行一次 setup
---------------------------------------------------------------------
local function ensure_setup()
	local todo2 = require("todo2")
	if not todo2.is_setup() then
		todo2.setup(vim.g.todo2_config)
	end
end

---------------------------------------------------------------------
-- 命令（惰性）
---------------------------------------------------------------------
vim.api.nvim_create_user_command("TodoSync", function()
	ensure_setup()
	require("todo2.commands").sync_current()
end, {})

vim.api.nvim_create_user_command("Todo2Heatmap", function()
	ensure_setup()
	require("todo2.commands").open_heatmap()
end, { desc = "打开热图" })

vim.api.nvim_create_user_command("SmartPreview", function()
	ensure_setup()
	require("todo2.commands").smart_preview()
end, { desc = "智能预览 TODO/代码" })

---------------------------------------------------------------------
-- 全局键（惰性；fallback 键保留原行为）
---------------------------------------------------------------------
local function map_fallback(lhs, handler, opts)
	opts = opts or {}
	vim.keymap.set("n", lhs, function()
		ensure_setup()
		if not handler() then
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
		end
	end, opts)
end

local function map(lhs, handler, desc)
	vim.keymap.set("n", lhs, function()
		ensure_setup()
		handler()
	end, { desc = desc })
end

-- 文件操作
map("<leader>mn", function() require("todo2.handlers").create_todo_file() end, "创建文件")
map("<leader>mr", function() require("todo2.handlers").rename_todo_file() end, "重命名文件")
map("<leader>md", function() require("todo2.handlers").delete_todo_file() end, "删除文件")

-- 归档 / 恢复
map("<leader>mg", function() require("todo2.ui.archive").archive_task_group() end, "归档任务组")
map("<leader>mu", function() require("todo2.ui.archive").restore_task() end, "恢复归档任务")

-- 状态操作
map_fallback("<CR>", function() return require("todo2.handlers").toggle_task_status() end, { desc = "切换任务状态" })
map_fallback("<BS>", function() return require("todo2.handlers").smart_delete() end, { desc = "智能删除任务" })
map("<leader>mt", function() require("todo2.ui.status").show_status_menu() end, "选择任务状态")
map_fallback("<c-[>", function() return require("todo2.handlers").cycle_status() end, { desc = "循环切换状态" })

-- 从代码创建任务
map("<leader>ma", function() require("todo2.creation.manager").start_session() end, "从代码创建任务")

-- 编辑任务
map_fallback("<S-CR>", function() return require("todo2.handlers").edit_task_from_code() end, { desc = "编辑任务内容" })

-- 链接操作
map("<leader>mq", function() require("todo2.handlers").show_project_links_qf() end, "显示所有双链标记 (QF)")
map("<leader>ml", function() require("todo2.handlers").show_buffer_links_loclist() end, "显示当前缓冲区双链标记 (LocList)")

-- 打开 TODO 文件
map("<leader>mf", function() require("todo2.handlers").open_todo_float() end, "浮窗打开")
map("<leader>ms", function() require("todo2.handlers").open_todo_split_horizontal() end, "水平分割打开")
map("<leader>mv", function() require("todo2.handlers").open_todo_split_vertical() end, "垂直分割打开")
map("<leader>me", function() require("todo2.handlers").open_todo_edit() end, "编辑模式打开")

-- 动态跳转 TODO <-> 代码
map_fallback("<s-tab>", function() return require("todo2.task.jumper").jump_dynamic() end, { desc = "动态跳转 TODO <-> 代码" })

---------------------------------------------------------------------
-- TODO 文件检测：打开 TODO 文件时惰性初始化并渲染
---------------------------------------------------------------------
local function todo_pattern()
	local default_globs = config.get("todo_files").globs
	local user = vim.g.todo2_config or {}
	local user_globs = user.todo_files and user.todo_files.globs
	local globs = (user_globs and #user_globs > 0) and user_globs or default_globs
	return table.concat(globs, ",")
end

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
	pattern = todo_pattern(),
	callback = function()
		ensure_setup()
		-- 当前 buffer 已错过 setup 内注册的 BufRead 事件，手动渲染一次
		local buf = vim.api.nvim_get_current_buf()
		vim.defer_fn(function()
			pcall(require("todo2.autocmds").render_buffer, buf)
		end, 50)
	end,
})
