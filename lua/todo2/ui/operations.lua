-- lua/todo2/ui/operations.lua
--- @module todo2.ui.operations

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 公共常量
---------------------------------------------------------------------
local TASK_PATTERN = "^%s*%-%s*%[%s*%]%s*(.*)"
local DONE_PATTERN = "^%s*%-%s*%[x%]%s*(.*)"
local ID_PATTERN = "{#([%w%-]+)}"

---------------------------------------------------------------------
-- 公共工具函数
---------------------------------------------------------------------

--- 格式化任务行
--- @param options table 任务选项
--- @return string 格式化后的任务行
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		content = "",
	}, options or {})

	local parts = { opts.indent, "- ", opts.checkbox }

	if opts.id then
		table.insert(parts, " {#" .. opts.id .. "}")
	end

	if opts.content and opts.content ~= "" then
		table.insert(parts, " ")
		table.insert(parts, opts.content)
	end

	return table.concat(parts, "")
end

--- 解析任务行
--- @param line string 任务行内容
--- @return table|nil 解析后的任务信息
function M.parse_task_line(line)
	if not line or line == "" then
		return nil
	end

	local indent = line:match("^(%s*)") or ""
	local level = #indent / 2 -- 假设每个缩进级别是2个空格

	local checkbox, content, id

	-- 检查是否是任务行
	if line:match("%[%s*%]") then
		checkbox = "[ ]"
		content = line:match(TASK_PATTERN)
	elseif line:match("%[x%]") then
		checkbox = "[x]"
		content = line:match(DONE_PATTERN)
	else
		return nil -- 不是任务行
	end

	-- 提取ID
	if content then
		id = content:match(ID_PATTERN)
		if id then
			content = content:gsub(ID_PATTERN, ""):gsub("%s+$", "")
		end
	end

	return {
		indent = indent,
		level = level,
		checkbox = checkbox,
		content = content or "",
		id = id,
		is_done = checkbox == "[x]",
		raw_line = line,
	}
end

--- 获取当前行缩进
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return string 缩进字符串
function M.get_line_indent(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return line:match("^(%s*)") or ""
end

--- 获取当前行的任务信息
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return table|nil 任务信息
function M.get_task_at_line(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return M.parse_task_line(line)
end

--- 确保任务有ID
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @param task table 任务对象（可选）
--- @return string|nil 任务ID
function M.ensure_task_id(bufnr, lnum, task)
	-- 如果传入了任务对象，且已有ID，直接返回
	if task and task.id then
		return task.id
	end

	-- 否则解析当前行
	task = task or M.get_task_at_line(bufnr, lnum)
	if not task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return nil
	end

	if task.id then
		return task.id
	end

	-- 生成新ID
	local link_module = module.get("link")
	if not link_module then
		vim.notify("无法获取 link 模块", vim.log.levels.ERROR)
		return nil
	end

	local new_id = link_module.generate_id()
	if not new_id then
		vim.notify("无法生成任务ID", vim.log.levels.ERROR)
		return nil
	end

	-- 构建新行
	local new_line = M.format_task_line({
		indent = task.indent,
		checkbox = task.checkbox,
		id = new_id,
		content = task.content,
	})

	-- 更新行
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })

	-- 更新store
	local store = module.get("store")
	if store then
		local path = vim.api.nvim_buf_get_name(bufnr)
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

		local prev = lnum > 1 and lines[lnum - 1] or ""
		local next = lnum < #lines and lines[lnum + 1] or ""

		store.add_todo_link(new_id, {
			path = path,
			line = lnum,
			content = task.content,
			created_at = os.time(),
			context = { prev = prev, curr = new_line, next = next },
		})
	end

	-- 触发事件
	local events = module.get("core.events")
	if events then
		events.on_state_changed({
			source = "ensure_task_id",
			file = vim.api.nvim_buf_get_name(bufnr),
			bufnr = bufnr,
			ids = { new_id },
		})
	end

	-- 自动保存
	local autosave = module.get("core.autosave")
	if autosave then
		autosave.request_save(bufnr)
	end

	return new_id
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

	-- 格式化任务行
	local line_content = M.format_task_line({
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
		local store = module.get("store")
		if store then
			local path = vim.api.nvim_buf_get_name(bufnr)
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

			local prev = new_line_num > 1 and lines[new_line_num - 1] or ""
			local next = new_line_num < #lines and lines[new_line_num + 1] or ""

			store.add_todo_link(opts.id, {
				path = path,
				line = new_line_num,
				content = opts.content,
				created_at = os.time(),
				context = { prev = prev, curr = line_content, next = next },
			})
		end
	end

	-- 触发事件
	if opts.trigger_event and opts.id then
		local events = module.get("core.events")
		if events then
			events.on_state_changed({
				source = opts.event_source,
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
				ids = { opts.id },
			})
		end
	end

	-- 自动保存
	if opts.autosave then
		local autosave = module.get("core.autosave")
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	return new_line_num, line_content
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

---------------------------------------------------------------------
-- UI操作函数
---------------------------------------------------------------------

--- 批量切换任务状态（统一处理可视模式）
--- @param bufnr number 缓冲区句柄
--- @param win number 窗口句柄
--- @return number 切换状态的任务数量
function M.toggle_selected_tasks(bufnr, win)
	local core = module.get("core")
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	local changed_count = 0

	for lnum = start_line, end_line do
		-- ⭐ 批量切换时，禁止 core.toggle_line 内部写盘
		local success, _ = core.toggle_line(bufnr, lnum, { skip_write = true })
		if success then
			changed_count = changed_count + 1
		end
	end

	-- ⭐ 统一写盘一次
	if changed_count > 0 then
		local autosave = module.get("core.autosave")
		if autosave then
			autosave.request_save(bufnr)
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
	local indent = M.get_line_indent(target_buf, lnum)
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
