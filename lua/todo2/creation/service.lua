-- lua/todo2/creation/service.lua
-- 服务层：协调创建任务的整个过程

local M = {}

local format = require("todo2.utils.format")
local store = require("todo2.store")
local core = require("todo2.store.link.core")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")
local context = require("todo2.utils.context")

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
-- 工具：从代码行提取 tag/id
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
-- 工具：提取上下文
---------------------------------------------------------------------
local function extract_context(bufnr, line, filepath)
	return context.build_from_buffer(bufnr, line, filepath)
end

---------------------------------------------------------------------
-- 创建内部任务（统一函数）
---------------------------------------------------------------------
local function create_internal_task(id, data)
	local now = os.time()

	local task = {
		id = id,
		core = {
			content = data.content or "",
			content_hash = require("todo2.utils.hash").hash(data.content or ""),
			status = data.status or "normal",
			tags = data.tag and { data.tag } or { "TODO" },
			ai_executable = data.ai_executable,
			sync_status = "local",
		},
		timestamps = {
			created = now,
			updated = now,
		},
		verification = {
			line_verified = true,
		},
		locations = {},
	}

	-- 设置位置
	if data.locations then
		task.locations = data.locations
	else
		if data.path and data.line then
			if data.type == "todo" then
				task.locations.todo = {
					path = data.path,
					line = data.line,
				}
			elseif data.type == "code" then
				task.locations.code = {
					path = data.path,
					line = data.line,
					context = data.context,
					context_updated_at = data.context and now or nil,
				}
			end
		end
	end

	return task
end

---------------------------------------------------------------------
-- 创建代码链接
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

	if not validate_line_number(bufnr, line) then
		vim.notify("创建代码链接失败：行号无效", vim.log.levels.ERROR)
		return false
	end

	local code_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	local extracted_tag, _ = extract_code_tag_id(code_line)
	local final_tag = tag or extracted_tag or "TODO"

	local ctx = extract_context(bufnr, line, path)
	if not ctx then
		vim.notify("创建代码链接失败：无法提取上下文", vim.log.levels.ERROR)
		return false
	end

	-- 内容来源：用户输入 或 默认值
	local final_content = content or "新任务"

	-- 检查是否已有任务
	local existing = core.get_task(id)
	if existing then
		existing.locations.code = {
			path = path,
			line = line,
			context = ctx,
			context_updated_at = os.time(),
		}
		existing.core.content = final_content
		existing.core.tags = { final_tag }
		existing.timestamps.updated = os.time()
		core.save_task(id, existing)
	else
		local task = create_internal_task(id, {
			content = final_content,
			tag = final_tag,
			type = "code",
			path = path,
			line = line,
			context = ctx,
		})
		core.save_task(id, task)
	end

	-- 更新索引
	local index = require("todo2.store.index")
	index._add_id_to_file_index("todo.index.file_to_code", path, id)

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
-- 创建 TODO 链接
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

	local final_content = content or "新任务"
	local final_tag = tag or "TODO"

	local existing = core.get_task(id)
	if existing then
		existing.locations.todo = {
			path = path,
			line = line,
		}
		existing.core.content = final_content
		existing.core.tags = { final_tag }
		existing.timestamps.updated = os.time()
		core.save_task(id, existing)
	else
		local task = create_internal_task(id, {
			content = final_content,
			tag = final_tag,
			type = "todo",
			path = path,
			line = line,
		})
		core.save_task(id, task)
	end

	local index = require("todo2.store.index")
	index._add_id_to_file_index("todo.index.file_to_todo", path, id)

	events.on_state_changed({
		source = "create_todo_link",
		file = path,
		ids = { id },
	})

	return true
end

---------------------------------------------------------------------
-- 插入任务行
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

	-- format_task_line 负责在写入文件时添加标签前缀
	local line_content = format.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		tag = opts.tag,
		content = opts.content,
	})

	local ok, result = pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { line_content })
		local new_line = lnum + 1

		if store.link and store.link.handle_line_shift then
			store.link.handle_line_shift(bufnr, new_line, 1)
		end

		if opts.update_store and opts.id then
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path ~= "" then
				local success = M.create_todo_link(path, new_line, opts.id, opts.content, opts.tag)
				if not success then
					error("创建TODO链接失败")
				end
			end
		end

		return new_line, line_content
	end)

	if not ok then
		vim.notify("插入任务行失败：" .. tostring(result), vim.log.levels.ERROR)
		return nil
	end

	local new_line, line_content = result

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
-- 插入任务到 TODO 文件
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
-- 创建子任务
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
