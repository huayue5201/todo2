--- File: /Users/lijia/todo2/lua/todo2/link/creator.lua ---
-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置模块
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local state = {
	creating_link = false,
	code_buf = nil,
	code_line = nil,
	original_win = nil,
	original_cursor = nil,
	selected_tag = nil,
	selected_todo_path = nil,
	todo_buf = nil,
	todo_win = nil,
}

---------------------------------------------------------------------
-- 清理状态
---------------------------------------------------------------------
local function cleanup_state()
	state = {
		creating_link = false,
		code_buf = nil,
		code_line = nil,
		original_win = nil,
		original_cursor = nil,
		selected_tag = nil,
		selected_todo_path = nil,
		todo_buf = nil,
		todo_win = nil,
	}
end

---------------------------------------------------------------------
-- 恢复原始窗口和光标
---------------------------------------------------------------------
local function restore_original_window()
	if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
		vim.api.nvim_set_current_win(state.original_win)
		if state.original_cursor then
			vim.api.nvim_win_set_cursor(state.original_win, state.original_cursor)
		end
	end
end

---------------------------------------------------------------------
-- 清理临时键位映射
---------------------------------------------------------------------
local function clear_temp_maps()
	if state.todo_buf and vim.api.nvim_buf_is_valid(state.todo_buf) then
		pcall(vim.keymap.del, "n", "<CR>", { buffer = state.todo_buf })
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = state.todo_buf })
	end
end

---------------------------------------------------------------------
-- 恢复 <CR> 默认映射
---------------------------------------------------------------------
local function reset_cr_mapping_to_default()
	if state.todo_buf and vim.api.nvim_buf_is_valid(state.todo_buf) then
		pcall(vim.keymap.del, "n", "<CR>", { buffer = state.todo_buf })
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = state.todo_buf })
	end
end

---------------------------------------------------------------------
-- 验证TODO文件有效性
---------------------------------------------------------------------
local function validate_todo_file(path)
	if not path then
		return false, "TODO文件路径为空"
	end
	local norm_path = vim.fn.fnamemodify(vim.fn.expand(path, ":p"), ":p")
	local stat = vim.loop.fs_stat(norm_path)
	if not stat or stat.type ~= "file" then
		return false, string.format("TODO文件不存在或不是文件：%s", norm_path)
	end
	local fd = vim.loop.fs_open(norm_path, "r", 438)
	if not fd then
		return false, string.format("TODO文件不可读：%s", norm_path)
	end
	vim.loop.fs_close(fd)
	return true, norm_path
end

---------------------------------------------------------------------
-- 插入任务行 - 复用 link.service 模块
---------------------------------------------------------------------
local function insert_task_line(bufnr, lnum, options)
	local link_service = module.get("link.service")
	if not link_service or not link_service.insert_task_line then
		return nil
	end
	return link_service.insert_task_line(bufnr, lnum, options)
end

---------------------------------------------------------------------
-- 在代码中插入标签 - 复用 link.utils 模块
---------------------------------------------------------------------
local function insert_code_tag_above(bufnr, line, id, tag)
	local link_utils = module.get("link.utils")
	if not link_utils or not link_utils.insert_code_tag_above then
		return false
	end
	return link_utils.insert_code_tag_above(bufnr, line, id, tag)
end

---------------------------------------------------------------------
-- 创建代码链接 - 复用 link.service 模块
---------------------------------------------------------------------
local function create_code_link(bufnr, line, id, content, tag)
	local link_service = module.get("link.service")
	if not link_service or not link_service.create_code_link then
		return false
	end
	return link_service.create_code_link(bufnr, line, id, content, tag)
end

---------------------------------------------------------------------
-- 从代码行提取标签 - 复用 format 模块
---------------------------------------------------------------------
local function extract_tag_from_code_line(code_line)
	local format = require("todo2.utils.format")
	return format.extract_from_code_line(code_line)
end

---------------------------------------------------------------------
-- 在 TODO 浮窗中按 <CR> 创建任务
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not state.creating_link then
		return
	end

	local valid, err = validate_todo_file(state.selected_todo_path)
	if not valid then
		vim.notify(string.format("创建链接失败：%s", err), vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	if not state.todo_buf or not vim.api.nvim_buf_is_valid(state.todo_buf) then
		vim.notify("创建链接失败：TODO缓冲区无效", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	if not state.code_buf or not state.code_line or not state.selected_tag then
		vim.notify("创建链接失败：状态不完整", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(current_win)
	local insert_line = cursor_pos[1]

	local link_module = module.get("link")
	if not link_module or not link_module.generate_id then
		vim.notify("创建链接失败：无法获取link模块", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end
	local new_id = link_module.generate_id()

	local task_content = "新任务"
	-- 插入任务行
	local new_line_num, line_content = insert_task_line(state.todo_buf, insert_line, {
		indent = "",
		checkbox = "[ ]",
		id = new_id,
		tag = state.selected_tag,
		content = task_content,
		update_store = true,
		trigger_event = true,
		autosave = true,
		event_source = "create_link",
	})

	if not new_line_num then
		vim.notify("创建链接失败：无法插入任务行", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	-- 在代码中插入TAG
	local tag_inserted = insert_code_tag_above(state.code_buf, state.code_line, new_id, state.selected_tag)

	-- 创建代码链接
	local code_link_ok = create_code_link(state.code_buf, state.code_line, new_id, task_content, state.selected_tag)

	-- 恢复 <CR> 的默认功能
	reset_cr_mapping_to_default()

	-- 清理创建状态，但保留TODO浮窗
	state.creating_link = false
	state.selected_tag = nil
	state.code_buf = nil
	state.code_line = nil
	state.original_win = nil
	state.original_cursor = nil
	state.selected_todo_path = nil

	-- 在TODO浮窗中移动光标到新创建的行
	if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
		vim.api.nvim_win_set_cursor(state.todo_win, { new_line_num, #line_content })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	-- 给用户提示
	local msg = string.format("链接创建成功！ID：%s，标签：%s", new_id, state.selected_tag)
	if not tag_inserted then
		msg = msg .. "（警告：代码TAG插入失败）"
	end
	if not code_link_ok then
		msg = msg .. "（警告：代码链接创建失败）"
	end
	vim.notify(msg, vim.log.levels.INFO)

	-- 特别提示：<CR> 已恢复默认功能
	vim.defer_fn(function()
		vim.notify("✅ 链接创建完成！现在 <CR> 已恢复默认功能", vim.log.levels.INFO)
	end, 100)
end

---------------------------------------------------------------------
-- 打开 TODO 文件并设置创建状态
---------------------------------------------------------------------
local function open_todo_file_and_setup(todo_path)
	local valid, norm_path = validate_todo_file(todo_path)
	if not valid then
		vim.notify(norm_path, vim.log.levels.ERROR)
		cleanup_state()
		restore_original_window()
		return
	end

	local ui = module.get("ui")
	if not ui or not ui.open_todo_file then
		vim.notify("创建链接失败：无法获取UI模块", vim.log.levels.ERROR)
		cleanup_state()
		restore_original_window()
		return
	end

	-- 接收buf和win两个返回值
	local todo_buf, todo_win = ui.open_todo_file(norm_path, "float", nil, {
		enter_insert = false,
		focus = true,
	})

	if not todo_buf or not todo_win then
		vim.notify(
			string.format("创建链接失败：无法打开TODO文件浮窗 %s", norm_path),
			vim.log.levels.ERROR
		)
		cleanup_state()
		restore_original_window()
		return
	end

	state.todo_buf = todo_buf
	state.todo_win = todo_win
	state.creating_link = true

	-- 清理可能存在的旧映射
	pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
	pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })

	-- 设置 <CR> 映射 - 只允许一次消费
	vim.keymap.set("n", "<CR>", function()
		if state.creating_link then
			-- 立即移除映射，确保只执行一次
			pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
			M.on_cr_in_todo()
		else
			vim.cmd("normal! <CR>")
		end
	end, {
		buffer = todo_buf,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "创建TODO-代码链接（仅限一次）",
	})

	-- 设置 <ESC> 映射
	vim.keymap.set("n", "<ESC>", function()
		pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })

		cleanup_state()
		vim.notify("已取消创建链接，<CR> 已恢复默认功能", vim.log.levels.INFO)
		restore_original_window()
	end, {
		buffer = todo_buf,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "取消创建链接",
	})

	vim.notify(
		"✅ 请移动光标到合适位置，按<CR>创建任务（仅限一次） | <ESC>取消",
		vim.log.levels.INFO
	)
end

---------------------------------------------------------------------
-- 选择 TODO 文件
---------------------------------------------------------------------
local function select_todo_file()
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local file_manager = module.get("ui.file_manager")

	if not file_manager or not file_manager.get_todo_files then
		vim.notify("创建链接失败：无法获取文件管理器模块", vim.log.levels.ERROR)
		cleanup_state()
		restore_original_window()
		return
	end

	local todo_files = file_manager.get_todo_files(project)
	if #todo_files == 0 then
		vim.notify("当前项目暂无TODO文件", vim.log.levels.WARN)
		cleanup_state()
		restore_original_window()
		return
	end

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
			return string.format("%-20s • %s", item.project, vim.fn.fnamemodify(item.path, ":t"))
		end,
	}, function(choice)
		if not choice then
			cleanup_state()
			restore_original_window()
			return
		end
		state.selected_todo_path = choice.path
		open_todo_file_and_setup(choice.path)
	end)
end

---------------------------------------------------------------------
-- 选择标签类型
---------------------------------------------------------------------
local function select_tag_type()
	local tags = config.get("tags") or {}
	local tag_choices = {}

	for tag, style in pairs(tags) do
		table.insert(tag_choices, {
			tag = tag,
			icon = style.icon or "",
			display = string.format("%s %s", style.icon or "", tag),
		})
	end

	if #tag_choices == 0 then
		table.insert(tag_choices, {
			tag = "TODO",
			icon = "📝",
			display = "📝 TODO",
		})
	end

	vim.ui.select(tag_choices, {
		prompt = "🏷️ 选择标签类型：",
		format_item = function(item)
			return string.format("%-12s • %s", item.tag, item.display)
		end,
	}, function(tag_item)
		if not tag_item then
			cleanup_state()
			restore_original_window()
			return
		end
		state.selected_tag = tag_item.tag
		select_todo_file()
	end)
end

---------------------------------------------------------------------
-- 主函数：创建链接
---------------------------------------------------------------------
function M.create_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	if file_path == "" then
		vim.notify("创建链接失败：当前缓冲区无文件路径", vim.log.levels.ERROR)
		return
	end

	-- 检查当前行是否已存在TAG标记 - 复用 format 模块
	local current_line = vim.api.nvim_get_current_line()
	local tag, id = extract_tag_from_code_line(current_line)
	if tag and id then
		vim.notify("创建链接失败：当前行已存在TAG标记", vim.log.levels.WARN)
		return
	end

	state.code_buf = bufnr
	state.code_line = vim.fn.line(".")
	state.original_win = vim.api.nvim_get_current_win()
	state.original_cursor = vim.api.nvim_win_get_cursor(state.original_win)

	select_tag_type()
end

---------------------------------------------------------------------
-- 快捷键映射
---------------------------------------------------------------------
function M.setup()
	vim.api.nvim_create_user_command("Todo2CreateLink", function()
		M.create_link()
	end, { desc = "创建代码与TODO的双向链接" })
end

---------------------------------------------------------------------
-- 导出状态
---------------------------------------------------------------------
M.get_state = function()
	return vim.deepcopy(state)
end

M.is_creating_link = function()
	return state.creating_link
end

return M
