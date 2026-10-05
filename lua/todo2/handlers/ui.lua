-- lua/todo2/handlers/ui.lua
-- UI 处理器：窗口 / 文件管理 / 插入 / 批量切换

local M = {}

local buffer = require("todo2.utils.buffer")
local window = require("todo2.ui.window")
local operations = require("todo2.creation.actions.operations")
local file_manager = require("todo2.ui.file_manager")

local function safe_close_window(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local wins = vim.api.nvim_list_wins()
	if #wins <= 1 then
		return false
	end

	local buf = vim.api.nvim_win_get_buf(win)
	local buf_wins = vim.fn.win_findbuf(buf)
	if #buf_wins <= 1 and #wins <= 2 then
		return false
	end

	pcall(vim.api.nvim_win_close, win, true)
	return true
end

--- 关闭当前浮动窗口（安全关闭）
function M.ui_close_window()
	local win_id = vim.api.nvim_get_current_win()
	safe_close_window(win_id)
end

--- 新建独立任务（无父、无代码链接）
function M.ui_insert_task()
	operations.insert_task(buffer.get_current_info().bufnr)
end

--- 在当前任务下新建子任务
function M.ui_insert_subtask()
	operations.insert_subtask(buffer.get_current_info().bufnr)
end

--- 在当前任务同级新建任务
function M.ui_insert_sibling()
	operations.insert_sibling(buffer.get_current_info().bufnr)
end

--- 切换选中任务的状态
function M.ui_toggle_selected()
	local info = buffer.get_current_info()
	local win = vim.fn.bufwinid(info.bufnr)
	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end
	return operations.toggle_selected_tasks(info.bufnr, win)
end

--- 打开 TODO 文件：先选择文件，再用指定模式/方向打开
local function open_todo(mode, split_direction)
	file_manager.select_todo_file("current", function(choice)
		if not choice then
			return
		end
		window.open_todo_file(choice.path, mode, 1, {
			enter_insert = false,
			split_direction = split_direction,
		})
	end)
end

--- 打开 TODO 文件（浮动窗口）
function M.open_todo_float()
	open_todo("float")
end

--- 打开 TODO 文件（水平分割）
function M.open_todo_split_horizontal()
	open_todo("split", "horizontal")
end

--- 打开 TODO 文件（垂直分割）
function M.open_todo_split_vertical()
	open_todo("split", "vertical")
end

--- 打开 TODO 文件（当前窗口编辑）
function M.open_todo_edit()
	open_todo("edit")
end

--- 创建新的 TODO 文件
function M.create_todo_file()
	file_manager.create_todo_file()
end

--- 重命名 TODO 文件
function M.rename_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.rename_todo_file(choice.path)
		end
	end)
end

--- 删除 TODO 文件
function M.delete_todo_file()
	file_manager.select_todo_file("current", function(choice)
		if choice then
			file_manager.delete_todo_file(choice.path)
		end
	end)
end

return M
