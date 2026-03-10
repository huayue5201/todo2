-- lua/todo2/ui/operations.lua
-- @module todo2.ui.operations
-- 最终版：UI 层不触发渲染，不直接写 store，不直接 autosave
-- 所有状态变化通过事件系统驱动 scheduler 渲染

local M = {}

---------------------------------------------------------------------
-- 依赖（仅 UI 所需）
---------------------------------------------------------------------
local core_utils = require("todo2.core.utils")
local events = require("todo2.core.events")
local service = require("todo2.creation.service") -- ⭐ 统一使用 service 层
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 批量切换任务状态（可视模式）
---------------------------------------------------------------------
function M.toggle_selected_tasks(bufnr, win)
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	local changed_count = 0
	local affected_ids = {}

	for lnum = start_line, end_line do
		local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

		if not line then
			goto continue
		end

		-----------------------------------------------------------------
		-- 1. 普通任务（无 ID）
		-----------------------------------------------------------------
		if line:match("^%s*- %[[ x]%]") and not line:match("{#") then
			local new_line
			if line:match("%[ %]") then
				new_line = line:gsub("%[ %]", "[x]", 1)
			elseif line:match("%[x%]") then
				new_line = line:gsub("%[x%]", "[ ]", 1)
			else
				goto continue
			end

			vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
			changed_count = changed_count + 1

			-- ⭐ 普通任务没有 ID，但仍然需要触发文件级事件
			events.on_state_changed({
				source = "toggle_plain_task",
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
			})

		-----------------------------------------------------------------
		-- 2. 双链任务（有 ID）
		-----------------------------------------------------------------
		elseif id_utils.contains_todo_anchor(line) then
			local id = id_utils.extract_id_from_todo_anchor(line)
			if id then
				-- ⭐ 直接修改文本
				local new_line
				if line:match("%[ %]") then
					new_line = line:gsub("%[ %]", "[x]", 1)
				elseif line:match("%[x%]") then
					new_line = line:gsub("%[x%]", "[ ]", 1)
				else
					goto continue
				end

				vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
				changed_count = changed_count + 1

				-- ⭐ 收集 ID，稍后触发事件
				table.insert(affected_ids, id)
			end
		end

		::continue::
	end

	---------------------------------------------------------------------
	-- 触发事件（仅双链任务）
	---------------------------------------------------------------------
	if #affected_ids > 0 then
		events.on_state_changed({
			source = "toggle_selected_tasks",
			file = vim.api.nvim_buf_get_name(bufnr),
			bufnr = bufnr,
			ids = affected_ids,
		})
	end

	-- 退出可视模式
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

	return changed_count
end

---------------------------------------------------------------------
-- 插入任务（UI 接口）
---------------------------------------------------------------------
function M.insert_task(text, indent_extra, bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	local indent = core_utils.get_line_indent(target_buf, lnum)
	indent = indent .. string.rep(" ", indent_extra or 0)

	-- ⭐ 统一调用 service 层（事件驱动）
	local new_line_num = service.insert_task_line(target_buf, lnum, {
		indent = indent,
		content = text or "新任务",
		update_store = false,
		trigger_event = false,
		autosave = true,
	})

	M.place_cursor_at_line_end(0, new_line_num)
	M.start_insert_at_line_end()
end

---------------------------------------------------------------------
-- 光标定位到行尾
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

---------------------------------------------------------------------
-- 进入插入模式（行尾）
---------------------------------------------------------------------
function M.start_insert_at_line_end()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

---------------------------------------------------------------------
-- 创建子任务（UI 调用 service）
---------------------------------------------------------------------
function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	return service.create_child_task(parent_bufnr, parent_task, child_id, content)
end

return M
