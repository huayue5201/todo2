-- lua/todo2/ui/operations.lua
-- UI 层，只处理用户交互

local M = {}

local state_manager = require("todo2.core.state_manager")
local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local format = require("todo2.utils.format")
local core = require("todo2.store.link.core") -- ⭐ 正确导入 core API

---------------------------------------------------------------------
-- 批量切换任务状态（可视模式）
---------------------------------------------------------------------
function M.toggle_selected_tasks(bufnr)
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	-- 修复：传入 opts 参数（可以为空表）
	local results = state_manager.toggle_range(bufnr, start_line, end_line, {})

	-- 退出可视模式
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

	return results.success
end

---------------------------------------------------------------------
-- 切换当前行任务（单行）
---------------------------------------------------------------------
function M.toggle_current_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	return state_manager.toggle_line(bufnr, lnum)
end

---------------------------------------------------------------------
-- 插入普通任务（增强版：写入数据库 + 继承 TAG + 继承 code 行号）
---------------------------------------------------------------------
function M.insert_task(text, indent_extra, bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	---------------------------------------------------------
	-- 1. 生成 ID
	---------------------------------------------------------
	local id = id_utils.generate_id()

	---------------------------------------------------------
	-- 2. 继承父任务 TAG（如果有父任务）
	---------------------------------------------------------
	local tag = "TODO"

	if lnum > 1 then
		local prev_line = vim.api.nvim_buf_get_lines(target_buf, lnum - 2, lnum - 1, false)[1]
		local parsed = format.parse_task_line(prev_line)
		if parsed and parsed.tag then
			tag = parsed.tag
		end
	end

	---------------------------------------------------------
	-- 3. 构造内容：TAG:ref:<id> 内容
	---------------------------------------------------------
	local content = string.format("%s:ref:%s %s", tag, id, text or "新任务")

	---------------------------------------------------------
	-- 4. 插入文本
	---------------------------------------------------------
	local result = service.insert_task_line(target_buf, lnum, {
		indent = indent_extra and string.rep(" ", indent_extra) or "",
		content = content,
		update_store = false,
		autosave = false,
	})

	if not result or not result.line_num then
		return
	end

	local new_line = result.line_num

	---------------------------------------------------------
	-- 5. 查找父任务 ID
	---------------------------------------------------------
	local parent_id = nil
	if new_line > 1 then
		local prev_line = vim.api.nvim_buf_get_lines(target_buf, new_line - 2, new_line - 1, false)[1]
		local parsed = format.parse_task_line(prev_line)
		if parsed and parsed.id then
			parent_id = parsed.id
		end
	end

	---------------------------------------------------------
	-- 6. 写入数据库（普通任务无 tag）
	---------------------------------------------------------
	service.create_todo_link(vim.api.nvim_buf_get_name(target_buf), new_line, id, text or "新任务", {
		tags = {},
		parent_id = parent_id,
	})

	---------------------------------------------------------
	-- 7. 继承父任务的 code 行号（轻量模式 B）
	---------------------------------------------------------
	if parent_id then
		local parent_task = core.get_task(parent_id)
		if parent_task and parent_task.locations and parent_task.locations.code then
			local code_loc = parent_task.locations.code

			-- ⭐ 使用正确的 API：update_code_location
			core.update_code_location(
				id,
				code_loc.path,
				code_loc.line,
				nil -- 不继承 context
			)
		end
	end

	---------------------------------------------------------
	-- 8. 光标移动
	---------------------------------------------------------
	M.place_cursor_at_line_end(0, new_line)
	M.start_insert_at_line_end()
end

---------------------------------------------------------------------
-- 光标工具函数
---------------------------------------------------------------------
function M.place_cursor_at_line_end(win, lnum)
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end

	local bufnr = vim.api.nvim_win_get_buf(win)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	vim.api.nvim_win_set_cursor(win, { lnum, #line })
end

function M.start_insert_at_line_end()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

---------------------------------------------------------------------
-- 创建子任务（保持不变）
---------------------------------------------------------------------
function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	return service.create_child_task(parent_bufnr, parent_task, child_id, content)
end

return M
