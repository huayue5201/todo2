-- lua/todo2/link/service.lua
--- @module todo2.link.service
--- @brief 统一的链接创建和管理服务

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具模块
---------------------------------------------------------------------
local utils = module.get("core.utils")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------

--- 提取上下文信息
local function extract_context(bufnr, line)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prev = line > 1 and lines[line - 2] or ""
	local curr = lines[line - 1] or ""
	local next = line < #lines and lines[line] or ""

	return {
		prev = prev,
		curr = curr,
		next = next,
	}
end

--- 格式化任务行（使用工具模块）
local function format_task_line(options)
	return utils.format_task_line(options)
end

--- 解析任务行（使用工具模块）
local function parse_task_line(line)
	return utils.parse_task_line(line)
end

---------------------------------------------------------------------
-- 核心服务函数
---------------------------------------------------------------------

--- 创建代码链接
function M.create_code_link(bufnr, line, id, content)
	if not bufnr or not line or not id then
		return false
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false
	end

	content = content or ""

	-- 提取上下文
	local context = extract_context(bufnr, line)

	-- 调用存储
	local store = module.get("store")
	local success = store.add_code_link(id, {
		path = path,
		line = line,
		content = content,
		created_at = os.time(),
		context = context,
	})

	if not success then
		return false
	end

	-- 触发事件
	local events = module.get("core.events")
	if events and events.on_state_changed then
		events.on_state_changed({
			source = "create_code_link",
			file = path,
			bufnr = bufnr,
			ids = { id },
		})
	end

	-- 自动保存
	local autosave = module.get("core.autosave")
	if autosave then
		autosave.request_save(bufnr)
	end

	return true
end

--- 创建TODO链接
function M.create_todo_link(path, line, id, content)
	if not path or not line or not id then
		return false
	end

	content = content or "新任务"

	-- 调用存储
	local store = module.get("store")
	local success = store.add_todo_link(id, {
		path = path,
		line = line,
		content = content,
		created_at = os.time(),
	})

	return success
end

--- 插入任务行（核心实现）
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
	local line_content = format_task_line({
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
		local path = vim.api.nvim_buf_get_name(bufnr)
		if path ~= "" then
			M.create_todo_link(path, new_line_num, opts.id, opts.content)
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

--- 确保任务有ID
function M.ensure_task_id(bufnr, lnum, task)
	return utils.ensure_task_id(bufnr, lnum, task)
end

--- 插入TODO任务到文件
function M.insert_task_to_todo_file(todo_path, id, task_content)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	-- 加载TODO文件buffer
	local bufnr = vim.fn.bufnr(todo_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("无法加载 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return nil
	end

	-- 获取插入位置
	local link_utils = module.get("link.utils")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = link_utils.find_task_insert_position(lines)

	-- 插入任务行
	local content = task_content or "新任务"
	local new_line_num = M.insert_task_line(bufnr, insert_line - 1, {
		indent = "",
		checkbox = "[ ]",
		id = id,
		content = content,
		autosave = true,
	})

	return new_line_num
end

--- 创建子任务
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
