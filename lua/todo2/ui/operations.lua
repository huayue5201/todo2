-- lua/todo2/ui/operations.lua
--- @module todo2.ui.operations

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local format = require("todo2.utils.format")
local core_utils = require("todo2.core.utils")
local store = require("todo2.store.link")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")

---------------------------------------------------------------------
-- UI操作函数（这些是UI特有的，保留）
---------------------------------------------------------------------
--- 批量切换任务状态（统一处理可视模式）
--- @param bufnr number 缓冲区句柄
--- @param win number 窗口句柄
--- @return number 切换状态的任务数量
function M.toggle_selected_tasks(bufnr, win)
	local core = require("todo2.core")
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	local changed_count = 0
	local affected_ids = {} -- ⭐ 收集所有受影响的ID

	for lnum = start_line, end_line do
		-- ⭐ 批量切换时，使用新版 toggle_line 获取受影响的任务ID
		local success, _, task_ids = core.toggle_line(bufnr, lnum, { skip_write = true })
		if success then
			changed_count = changed_count + 1
			-- 合并受影响的ID
			if task_ids then
				for _, id in ipairs(task_ids) do
					if not vim.tbl_contains(affected_ids, id) then
						table.insert(affected_ids, id)
					end
				end
			end
		end
	end

	-- ⭐ 统一写盘一次，并触发事件
	if changed_count > 0 then
		if autosave then
			autosave.request_save(bufnr)
		end

		-- 触发事件（检查是否已经在处理中）
		if #affected_ids > 0 and events then
			local event_data = {
				source = "toggle_selected_tasks",
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
				ids = affected_ids,
			}

			-- 检查是否已经有相同的事件在处理中
			if not events.is_event_processing(event_data) then
				events.on_state_changed(event_data)
			end
		end
	end

	-- 退出可视模式
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

	return changed_count
end

--- 插入任务（UI接口）
--- @param text string 任务内容
--- @param indent_extra number 额外缩进
--- @param bufnr number 缓冲区句柄（可选）
--- @param ui_module table UI模块（可选）
function M.insert_task(text, indent_extra, bufnr, ui_module)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	-- 获取当前行缩进
	local indent = core_utils.get_line_indent(target_buf, lnum)
	indent = indent .. string.rep(" ", indent_extra or 0)

	-- 使用公共方法插入任务
	local new_line_num = M.insert_task_line(target_buf, lnum, {
		indent = indent,
		content = text or "新任务",
		update_store = false, -- 简单插入不需要store
		trigger_event = false,
		autosave = true,
	})

	-- 更新虚拟文本和高亮
	if ui_module and ui_module.refresh then
		ui_module.refresh(target_buf)
	end

	-- 移动光标并进入插入模式
	M.place_cursor_at_line_end(0, new_line_num)
	M.start_insert_at_line_end()
end

--- 光标定位到行尾
--- @param win number 窗口句柄（可选，默认当前窗口）
--- @param lnum number 行号（1-indexed）
function M.place_cursor_at_line_end(win, lnum)
	win = win or vim.api.nvim_get_current_win()

	if not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end

	local bufnr = vim.api.nvim_win_get_buf(win)
	local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)

	if #lines == 0 then
		vim.api.nvim_win_set_cursor(win, { lnum, 0 })
		return
	end

	local line = lines[1]
	local col = #line

	vim.api.nvim_win_set_cursor(win, { lnum, col })
end

--- 进入插入模式（到行尾）
function M.start_insert_at_line_end()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

--- 插入任务行（公共方法）
--- @param bufnr number 缓冲区句柄
--- @param lnum number 在指定行之后插入（1-indexed）
--- @param options table 插入选项
--- @return number, string 新行号和新行内容
function M.insert_task_line(bufnr, lnum, options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		content = "",
		update_store = true,
		trigger_event = true,
		autosave = true,
		event_source = "insert_task_line",
	}, options or {})

	-- 直接使用 format 模块格式化任务行
	local line_content = format.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		content = opts.content,
	})

	-- 插入行
	vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { line_content })
	local new_line_num = lnum + 1

	-- 更新store
	if opts.update_store and opts.id then
		if store then
			local path = vim.api.nvim_buf_get_name(bufnr)
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

			local prev = new_line_num > 1 and lines[new_line_num - 1] or ""
			local next = new_line_num < #lines and lines[new_line_num + 1] or ""

			store.add_todo(opts.id, {
				path = path,
				line = new_line_num,
				content = opts.content,
				created_at = os.time(),
				context = { prev = prev, curr = line_content, next = next },
			})
		end
	end

	-- ⭐ 修改事件触发部分
	if opts.trigger_event and opts.id then
		if events then
			local event_data = {
				source = opts.event_source,
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
				ids = { opts.id },
			}

			-- 检查是否已经有相同的事件在处理中
			if not events.is_event_processing(event_data) then
				events.on_state_changed(event_data)
			end
		end
	end

	-- ⭐ 修改保存部分
	if opts.autosave then
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	return new_line_num, line_content
end

--- 创建子任务（供child模块调用）
--- @param parent_bufnr number 父任务缓冲区句柄
--- @param parent_task table 父任务对象
--- @param child_id string 子任务ID
--- @param content string 子任务内容（可选）
--- @return number 新任务行号
function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	content = content or "新任务"
	local parent_indent = string.rep("  ", parent_task.level or 0)
	local child_indent = parent_indent .. "  "

	return M.insert_task_line(parent_bufnr, parent_task.line_num, {
		indent = child_indent,
		id = child_id,
		content = content,
		event_source = "create_child_task",
	})
end

return M
