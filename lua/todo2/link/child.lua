--- File: /Users/lijia/todo2/lua/todo2/link/child.lua ---
-- lua/todo2/link/child.lua
--- @module todo2.child

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
	creating_child = false,
	code_buf = nil,
	code_row = nil,
	selected_tag = nil,
	selected_todo_path = nil,
	todo_buf = nil,
	todo_win = nil,
	original_win = nil,
	original_cursor = nil,
}

---------------------------------------------------------------------
-- 内部工具函数 - 复用已有模块
---------------------------------------------------------------------

--- 获取缩进宽度
local function get_indent_width()
	local indent_width = config.get("indent_width")
	return indent_width and indent_width > 0 and indent_width or 2
end

--- 计算子任务缩进 - 复用已有函数
local function calculate_child_indent(parent_task, parent_line)
	if not parent_task then
		return ""
	end

	local indent_width = get_indent_width()

	-- 获取父任务的实际缩进
	local parent_indent = ""
	if parent_task.indent then
		parent_indent = parent_task.indent
	elseif parent_line then
		-- 使用core.utils中的函数获取行缩进
		local core_utils = module.get("core.utils")
		if core_utils and core_utils.get_line_indent then
			parent_indent = core_utils.get_line_indent(state.todo_buf, parent_task.line_num)
		else
			parent_indent = parent_line:match("^[ \t]*") or ""
		end
	end

	-- 计算子任务缩进：在父任务缩进基础上增加一级
	local child_indent
	if parent_indent:find("\t") then
		child_indent = parent_indent .. "\t"
	else
		child_indent = parent_indent .. string.rep(" ", indent_width)
	end

	return child_indent
end

--- 插入任务行 - 复用 link.service 模块
local function insert_task_line(bufnr, lnum, options)
	local link_service = module.get("link.service")
	if not link_service or not link_service.insert_task_line then
		return nil
	end
	return link_service.insert_task_line(bufnr, lnum, options)
end

--- 在代码中插入标签 - 复用 link.utils 模块
local function insert_code_tag_above(bufnr, line, id, tag)
	local link_utils = module.get("link.utils")
	if not link_utils or not link_utils.insert_code_tag_above then
		return false
	end
	return link_utils.insert_code_tag_above(bufnr, line, id, tag)
end

--- 创建代码链接 - 复用 link.service 模块
local function create_code_link(bufnr, line, id, content, tag)
	local link_service = module.get("link.service")
	if not link_service or not link_service.create_code_link then
		return false
	end
	return link_service.create_code_link(bufnr, line, id, content, tag)
end

--- 创建子任务 - 复用已有函数
local function create_child_task(todo_buf, parent_task, child_id, child_content, child_tag)
	if not todo_buf or not parent_task or not child_id then
		return nil
	end

	-- 获取父任务行内容
	local parent_line = vim.api.nvim_buf_get_lines(todo_buf, parent_task.line_num - 1, parent_task.line_num, false)[1]
		or ""

	-- 计算子任务缩进
	local child_indent = calculate_child_indent(parent_task, parent_line)

	-- 在父任务下一行插入子任务
	local insert_line = parent_task.line_num

	local new_line_num, line_content = insert_task_line(todo_buf, insert_line, {
		indent = child_indent,
		checkbox = "[ ]",
		id = child_id,
		tag = child_tag,
		content = child_content,
		update_store = true,
		trigger_event = true,
		event_source = "create_child_task",
	})

	return new_line_num
end

---------------------------------------------------------------------
-- 清理状态
---------------------------------------------------------------------
local function cleanup_state()
	state = {
		creating_child = false,
		code_buf = nil,
		code_row = nil,
		selected_tag = nil,
		selected_todo_path = nil,
		todo_buf = nil,
		todo_win = nil,
		original_win = nil,
		original_cursor = nil,
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
-- 使用 parser 准确判断任务行
---------------------------------------------------------------------
local function get_parsed_task_at_line(bufnr, row)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return nil
	end

	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	local tasks, _ = parser.parse_file(path)
	if not tasks then
		return nil
	end

	for _, task in ipairs(tasks) do
		if task.line_num == row then
			return task
		end
	end

	return nil
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
-- 从代码行提取标签 - 复用 format 模块
---------------------------------------------------------------------
local function extract_tag_from_code_line(code_line)
	local format = require("todo2.utils.format")
	return format.extract_from_code_line(code_line)
end

---------------------------------------------------------------------
-- 在 TODO 浮窗中按 <CR> 创建子任务
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not state.creating_child then
		return
	end

	-- 验证TODO文件
	local valid, err = validate_todo_file(state.selected_todo_path)
	if not valid then
		vim.notify(string.format("创建子任务失败：%s", err), vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	if not state.todo_buf or not vim.api.nvim_buf_is_valid(state.todo_buf) then
		vim.notify("创建子任务失败：TODO缓冲区无效", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	if not state.code_buf or not state.code_row or not state.selected_tag then
		vim.notify("创建子任务失败：状态不完整", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	-- 保存当前浮窗信息
	local current_win = vim.api.nvim_get_current_win()
	local current_row = vim.api.nvim_win_get_cursor(current_win)[1]

	-- 1. 使用 parser 准确判断当前行是否是任务行
	local parent_task = get_parsed_task_at_line(state.todo_buf, current_row)
	if not parent_task then
		vim.notify("当前行不是有效的任务行，请选择父任务", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有 ID
	local core_utils = module.get("core.utils")
	if not core_utils then
		vim.notify("无法获取工具模块", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	local parent_id = core_utils.ensure_task_id(state.todo_buf, current_row, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	-- 3. 生成子任务 ID
	local link_module = module.get("link")
	if not link_module or not link_module.generate_id then
		vim.notify("无法获取链接模块", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	local new_id = link_module.generate_id()

	-- 4. 插入子任务
	local child_content = "新任务"
	local child_row = create_child_task(state.todo_buf, parent_task, new_id, child_content, state.selected_tag)

	if not child_row then
		vim.notify("无法创建子任务", vim.log.levels.ERROR)
		cleanup_state()
		clear_temp_maps()
		return
	end

	-- 5. 在代码中插入TAG（复用 link.utils 模块）
	insert_code_tag_above(state.code_buf, state.code_row, new_id, state.selected_tag)

	-- 6. 创建代码链接（复用 link.service 模块）
	local cleaned_content = child_content
	local format = module.get("todo2.utils.format")
	cleaned_content = format.clean_content(child_content, state.selected_tag)
	create_code_link(state.code_buf, state.code_row, new_id, cleaned_content, state.selected_tag)

	-- 恢复 <CR> 的默认功能
	reset_cr_mapping_to_default()

	-- 清理创建状态，但保留TODO浮窗
	state.creating_child = false
	state.selected_tag = nil
	state.code_buf = nil
	state.code_row = nil
	state.original_win = nil
	state.original_cursor = nil
	state.selected_todo_path = nil

	-- 在TODO浮窗中移动光标到新创建的子任务行
	if state.todo_win and vim.api.nvim_win_is_valid(state.todo_win) then
		local line_content = vim.api.nvim_buf_get_lines(state.todo_buf, child_row - 1, child_row, false)[1] or ""
		local col = #line_content
		vim.api.nvim_win_set_cursor(state.todo_win, { child_row, col })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	-- 给用户提示
	local msg = string.format(
		"子任务创建成功！ID：%s，标签：%s，父任务：%s",
		new_id,
		state.selected_tag,
		parent_id
	)
	vim.notify(msg, vim.log.levels.INFO)

	-- 特别提示：<CR> 已恢复默认功能
	vim.defer_fn(function()
		vim.notify("✅ 子任务创建完成！现在 <CR> 已恢复默认功能", vim.log.levels.INFO)
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
		vim.notify("创建子任务失败：无法获取UI模块", vim.log.levels.ERROR)
		cleanup_state()
		restore_original_window()
		return
	end

	-- 打开TODO文件浮窗
	local todo_buf, todo_win = ui.open_todo_file(norm_path, "float", nil, {
		enter_insert = false,
		focus = true,
	})

	if not todo_buf or not todo_win then
		vim.notify(
			string.format("创建子任务失败：无法打开TODO文件浮窗 %s", norm_path),
			vim.log.levels.ERROR
		)
		cleanup_state()
		restore_original_window()
		return
	end

	state.todo_buf = todo_buf
	state.todo_win = todo_win
	state.creating_child = true

	-- 清理可能存在的旧映射
	pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
	pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })

	-- 设置 <CR> 映射 - 只允许一次消费
	vim.keymap.set("n", "<CR>", function()
		if state.creating_child then
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
		desc = "选择父任务并创建子任务（仅限一次）",
	})

	-- 设置 <ESC> 映射
	vim.keymap.set("n", "<ESC>", function()
		pcall(vim.keymap.del, "n", "<CR>", { buffer = todo_buf })
		pcall(vim.keymap.del, "n", "<ESC>", { buffer = todo_buf })

		cleanup_state()
		vim.notify("已取消创建子任务，<CR> 已恢复默认功能", vim.log.levels.INFO)
		restore_original_window()
	end, {
		buffer = todo_buf,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "取消创建子任务",
	})

	vim.notify(
		"✅ 请选择父任务（光标移动到父任务行），按<CR>创建子任务（仅限一次） | <ESC>取消",
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
		vim.notify("创建子任务失败：无法获取文件管理器模块", vim.log.levels.ERROR)
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
		prompt = "🏷️ 选择子任务标签类型：",
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
-- 主函数：从代码创建子任务
---------------------------------------------------------------------
function M.create_child_from_code()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	if file_path == "" then
		vim.notify("创建子任务失败：当前缓冲区无文件路径", vim.log.levels.ERROR)
		return
	end

	-- 检查当前行是否已存在TAG标记 - 复用 format 模块
	local current_line = vim.api.nvim_get_current_line()
	local tag, id = extract_tag_from_code_line(current_line)
	if tag and id then
		vim.notify("创建子任务失败：当前行已存在TAG标记", vim.log.levels.WARN)
		return
	end

	state.code_buf = bufnr
	state.code_row = vim.fn.line(".")
	state.original_win = vim.api.nvim_get_current_win()
	state.original_cursor = vim.api.nvim_win_get_cursor(state.original_win)

	select_tag_type()
end

---------------------------------------------------------------------
-- 快捷键映射
---------------------------------------------------------------------
function M.setup()
	vim.api.nvim_create_user_command("Todo2CreateChild", function()
		M.create_child_from_code()
	end, { desc = "从代码行创建子任务" })
end

---------------------------------------------------------------------
-- 导出状态
---------------------------------------------------------------------
M.get_state = function()
	return vim.deepcopy(state)
end

M.is_creating_child = function()
	return state.creating_child
end

return M
