-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置模块（新增）
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- ⭐ 标签管理器（新增）
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local creating_link = false
local pending = {
	code_buf = nil,
	code_line = nil,
	original_win = nil,
	original_cursor = nil,
	selected_tag = nil,
	selected_todo_path = nil,
}

---------------------------------------------------------------------
-- 清理状态
---------------------------------------------------------------------
local function cleanup_state()
	creating_link = false
	pending.code_buf = nil
	pending.code_line = nil
	pending.original_win = nil
	pending.original_cursor = nil
	pending.selected_tag = nil
	pending.selected_todo_path = nil
end

---------------------------------------------------------------------
-- ⭐ 恢复原始窗口和光标
---------------------------------------------------------------------
local function restore_original_window()
	if pending.original_win and vim.api.nvim_win_is_valid(pending.original_win) then
		vim.api.nvim_set_current_win(pending.original_win)

		if pending.original_cursor then
			vim.api.nvim_win_set_cursor(pending.original_win, pending.original_cursor)
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 清理临时键位映射
---------------------------------------------------------------------
local function clear_temp_maps(todo_buf)
	if todo_buf and vim.api.nvim_buf_is_valid(todo_buf) then
		pcall(function()
			vim.keymap.del("n", "<CR>", { buffer = todo_buf })
		end)
		pcall(function()
			vim.keymap.del("n", "<ESC>", { buffer = todo_buf })
		end)
	end
end

---------------------------------------------------------------------
-- ⭐ 在 TODO 浮窗中按 <CR> 创建任务
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not creating_link then
		return
	end

	-- 保存当前浮窗信息
	local float_win = vim.api.nvim_get_current_win()
	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]

	-- 确保有必要的状态
	if not pending.code_buf or not pending.code_line or not pending.selected_tag then
		vim.notify("创建链接时发生错误：状态不完整", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps(tbuf)
		return
	end

	-- 1. 生成 ID（与 child.lua 保持一致，从 link 模块获取）
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 2. 使用统一服务插入任务行
	local link_service = module.get("link.service")
	if not link_service then
		vim.notify("无法获取链接服务模块", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps(tbuf)
		return
	end

	-- ⭐ 修改：任务内容应该是纯文本，不包含标签前缀
	local task_content = "新任务" -- 纯文本内容

	local new_line_num = link_service.insert_task_line(tbuf, trow, {
		indent = "", -- 顶级任务，无缩进
		checkbox = "[ ]",
		id = new_id,
		tag = pending.selected_tag, -- ⭐ 传递标签
		content = task_content, -- 纯文本内容
		update_store = true,
		trigger_event = true,
		autosave = true,
		event_source = "create_link", -- 标记事件来源
	})

	if not new_line_num then
		vim.notify("无法在 TODO 文件中插入任务", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps(tbuf)
		return
	end

	-- 3. 在代码中插入 TAG（现在会使用正确的tag）
	local utils = module.get("link.utils")
	if utils and utils.insert_code_tag_above then
		utils.insert_code_tag_above(pending.code_buf, pending.code_line, new_id, pending.selected_tag)
	else
		-- 备选方案：直接插入代码 TAG
		local tag_line = string.format("%s:ref:%s", pending.selected_tag, new_id)
		vim.api.nvim_buf_set_lines(pending.code_buf, pending.code_line - 1, pending.code_line - 1, false, { tag_line })
	end

	-- 4. 使用统一服务创建代码链接（传递标签）
	link_service.create_code_link(pending.code_buf, pending.code_line, new_id, task_content, pending.selected_tag)

	-- 5. 清理状态
	cleanup_state()
	clear_temp_maps(tbuf)

	-- 6. 确保回到正确的窗口
	if vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_set_current_win(float_win)

		if vim.api.nvim_win_get_buf(float_win) ~= tbuf then
			vim.api.nvim_win_set_buf(float_win, tbuf)
		end

		-- 定位光标到新任务行并进入插入模式
		vim.api.nvim_win_set_cursor(float_win, { new_line_num, 0 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	vim.notify(
		string.format("链接 %s 创建成功（使用标签：%s）", new_id, pending.selected_tag),
		vim.log.levels.INFO
	)
end

---------------------------------------------------------------------
-- ⭐ 直接打开 TODO 文件并设置创建状态
---------------------------------------------------------------------
local function open_todo_file_and_setup(todo_path)
	-- 打开 TODO 文件浮窗
	local ui = module.get("ui")
	local todo_buf, todo_win = ui.open_todo_file(todo_path, "float", nil, {
		enter_insert = false,
		focus = true,
	})

	if not todo_buf or not todo_win then
		vim.notify("无法打开 TODO 文件", vim.log.levels.ERROR)
		cleanup_state()
		restore_original_window()
		return
	end

	-- 设置创建链接状态
	creating_link = true
	vim.notify("请移动光标到合适位置，然后按<CR>创建任务", vim.log.levels.INFO)

	-- 设置临时键位
	vim.keymap.set("n", "<CR>", function()
		if creating_link then
			M.on_cr_in_todo()
			clear_temp_maps(todo_buf)
		else
			vim.cmd("normal! <CR>")
		end
	end, { buffer = todo_buf, noremap = true, silent = true, desc = "在当前位置创建任务" })

	vim.keymap.set("n", "<ESC>", function()
		cleanup_state()
		clear_temp_maps(todo_buf)
		vim.notify("已取消创建链接", vim.log.levels.INFO)
		restore_original_window()
	end, { buffer = todo_buf, noremap = true, silent = true, desc = "取消创建链接" })
end

---------------------------------------------------------------------
-- ⭐ 选择 TODO 文件
---------------------------------------------------------------------
local function select_todo_file()
	-- 获取 TODO 文件列表
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local file_manager = module.get("ui.file_manager")
	local todo_files = file_manager.get_todo_files(project)

	if #todo_files == 0 then
		vim.notify("当前项目没有 TODO 文件", vim.log.levels.WARN)
		cleanup_state()
		restore_original_window()
		return
	end

	-- 构建选择列表
	local choices = {}
	for _, f in ipairs(todo_files) do
		table.insert(choices, {
			project = project,
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	vim.ui.select(choices, {
		prompt = "🗂️ 选择 TODO 文件：",
		format_item = function(item)
			return string.format("%-20s • %s", item.project or project, vim.fn.fnamemodify(item.path, ":t"))
		end,
	}, function(choice)
		if not choice then
			cleanup_state()
			restore_original_window()
			return
		end

		pending.selected_todo_path = choice.path
		open_todo_file_and_setup(choice.path)
	end)
end

---------------------------------------------------------------------
-- ⭐ 选择标签类型
---------------------------------------------------------------------
local function select_tag_type()
	-- 修复：使用新的配置模块获取tags
	local tags = config.get("tags") or {}
	local tag_choices = {}

	for tag, style in pairs(tags) do
		table.insert(tag_choices, {
			tag = tag,
			icon = style.icon or "",
			display = string.format("%s  %s", style.icon or "", tag),
		})
	end

	-- 如果tags为空，添加默认选项
	if #tag_choices == 0 then
		table.insert(tag_choices, {
			tag = "TODO",
			icon = "",
			display = "TODO",
		})
	end

	vim.ui.select(tag_choices, {
		prompt = "🏷️ 选择标签类型：",
		format_item = function(item)
			return item.display
		end,
	}, function(tag_item)
		if not tag_item then
			cleanup_state()
			restore_original_window()
			return
		end

		pending.selected_tag = tag_item.tag
		select_todo_file()
	end)
end

---------------------------------------------------------------------
-- ⭐ 主函数：创建链接
---------------------------------------------------------------------
function M.create_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	if file_path == "" then
		vim.notify("无法创建链接：当前 buffer 没有文件路径", vim.log.levels.ERROR)
		return
	end

	-- 检查当前行是否已有 TAG
	local line = vim.api.nvim_get_current_line()
	if line and line:match("%u+:ref:%w+") then
		vim.notify("当前行已有 TAG 标记，请选择其他位置", vim.log.levels.WARN)
		return
	end

	-- 保存原始状态
	pending.code_buf = bufnr
	pending.code_line = vim.fn.line(".")
	pending.original_win = vim.api.nvim_get_current_win()
	pending.original_cursor = vim.api.nvim_win_get_cursor(pending.original_win)

	-- 开始创建链接流程
	select_tag_type()
end

---------------------------------------------------------------------
-- ⭐ 快捷键映射（可选）
---------------------------------------------------------------------
function M.setup()
	vim.api.nvim_create_user_command("Todo2CreateLink", function()
		M.create_link()
	end, { desc = "创建代码与 TODO 的链接" })
end

return M
