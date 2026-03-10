-- lua/todo2/creation/service.lua
-- 最终精简版：无动态匹配，写入即真相，结构化解析

local M = {}

local format = require("todo2.utils.format")
local store = require("todo2.store")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 工具：校验行号
---------------------------------------------------------------------
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line >= 1 and line <= total
end

---------------------------------------------------------------------
-- 工具：从代码行结构化提取 tag/id
-- 不再使用任何正则推断
---------------------------------------------------------------------
local function extract_code_tag_id(line)
	if not line then
		return nil, nil
	end
	local id = id_utils.extract_id_from_code_mark(line)
	local tag = id_utils.extract_tag_from_code_mark(line)
	return tag or "TODO", id
end

---------------------------------------------------------------------
-- 工具：提取上下文（保持不变）
---------------------------------------------------------------------
local function extract_context(bufnr, line, id, tag)
	local context_module = require("todo2.store.context")
	local pattern = id_utils.format_code_mark(tag, id)

	local ctx = context_module.build_from_pattern(bufnr, pattern, vim.api.nvim_buf_get_name(bufnr))
	if ctx then
		return ctx
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prev = line > 1 and lines[line - 2] or ""
	local curr = lines[line - 1] or ""
	local next = line < #lines and lines[line] or ""
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	return context_module.build(prev, curr, next, filepath, line)
end

---------------------------------------------------------------------
-- ⭐ 创建代码链接（无动态匹配）
---------------------------------------------------------------------
function M.create_code_link(bufnr, line, id, content, tag)
	if not bufnr or not line or not id then
		vim.notify("创建代码链接失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	if not id_utils.is_valid(id) then
		vim.notify("创建代码链接失败：ID格式无效 " .. id, vim.log.levels.ERROR)
		return false
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		vim.notify("创建代码链接失败：buffer没有文件路径", vim.log.levels.ERROR)
		return false
	end

	-- ⭐ 不再动态查找行号，写入即真相
	if not validate_line_number(bufnr, line) then
		vim.notify("创建代码链接失败：行号无效", vim.log.levels.ERROR)
		return false
	end

	local code_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	content = content or code_line

	-- ⭐ 从结构化格式提取 tag
	local extracted_tag, _ = extract_code_tag_id(code_line)
	local final_tag = tag or extracted_tag or "TODO"

	local context = extract_context(bufnr, line, id, final_tag)

	local cleaned_content = format.clean_content(content, final_tag, { full_clean = false })

	local success = store.link.add_code(id, {
		path = path,
		line = line,
		content = cleaned_content,
		tag = final_tag,
		created_at = os.time(),
		context = context,
		context_updated_at = os.time(),
	})

	if not success then
		vim.notify("创建代码链接失败：存储操作失败", vim.log.levels.ERROR)
		return false
	end

	-- ⭐ 事件驱动渲染
	events.on_state_changed({
		source = "create_code_link",
		file = path,
		bufnr = bufnr,
		ids = { id },
	})

	if autosave then
		autosave.request_save(bufnr)
	end

	return true
end

---------------------------------------------------------------------
-- 创建 TODO 链接（保持结构化）
---------------------------------------------------------------------
function M.create_todo_link(path, line, id, content, tag)
	if not path or not line or not id then
		vim.notify("创建TODO链接失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	if not id_utils.is_valid(id) then
		vim.notify("创建TODO链接失败：ID格式无效 " .. id, vim.log.levels.ERROR)
		return false
	end

	content = content or "新任务"

	local cleaned = format.clean_content(content, tag or "TODO", { full_clean = true })

	return store.link.add_todo(id, {
		path = path,
		line = line,
		content = cleaned,
		tag = tag or "TODO",
		created_at = os.time(),
	})
end

---------------------------------------------------------------------
-- 插入任务行（结构化写入）
---------------------------------------------------------------------
function M.insert_task_line(bufnr, lnum, options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = nil,
		content = "",
		update_store = true,
		trigger_event = true,
		autosave = true,
		event_source = "insert_task_line",
	}, options or {})

	if opts.id and not id_utils.is_valid(opts.id) then
		vim.notify("插入任务行失败：ID格式无效 " .. opts.id, vim.log.levels.ERROR)
		return nil
	end

	local line_content = format.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		tag = opts.tag,
		content = opts.content,
	})

	vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { line_content })
	local new_line = lnum + 1

	if store.link and store.link.handle_line_shift then
		store.link.handle_line_shift(bufnr, new_line, 1)
	end

	if opts.update_store and opts.id then
		local path = vim.api.nvim_buf_get_name(bufnr)
		if path ~= "" then
			M.create_todo_link(path, new_line, opts.id, opts.content, opts.tag)
		end
	end

	if opts.trigger_event and opts.id then
		events.on_state_changed({
			source = opts.event_source,
			file = vim.api.nvim_buf_get_name(bufnr),
			bufnr = bufnr,
			ids = { opts.id },
		})
	end

	if opts.autosave and autosave then
		autosave.request_save(bufnr)
	end

	return new_line, line_content
end

---------------------------------------------------------------------
-- 插入任务到 TODO 文件（结构化）
---------------------------------------------------------------------
function M.insert_task_to_todo_file(todo_path, id, task_content)
	if not id_utils.is_valid(id) then
		vim.notify("插入TODO任务失败：ID格式无效 " .. id, vim.log.levels.ERROR)
		return nil
	end

	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	local bufnr = vim.fn.bufnr(todo_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("无法加载 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = link_utils.find_task_insert_position(lines)

	local content = task_content or "新任务"
	local new_line = M.insert_task_line(bufnr, insert_line - 1, {
		indent = "",
		checkbox = "[ ]",
		id = id,
		content = content,
		autosave = true,
	})

	return new_line
end

---------------------------------------------------------------------
-- 创建子任务（结构化）
---------------------------------------------------------------------
function M.create_child_task(parent_bufnr, parent_task, child_id, content, tag)
	if not id_utils.is_valid(child_id) then
		vim.notify("创建子任务失败：ID格式无效 " .. child_id, vim.log.levels.ERROR)
		return nil
	end

	content = content or "新任务"
	local parent_indent = string.rep("  ", parent_task.level or 0)
	local child_indent = parent_indent .. "  "

	return M.insert_task_line(parent_bufnr, parent_task.line_num, {
		indent = child_indent,
		id = child_id,
		tag = tag,
		content = content,
		event_source = "create_child_task",
	})
end

return M
