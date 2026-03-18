-- lua/todo2/creation/service.lua
-- 服务层：协调创建任务的整个过程，确保数据完整写入
---@module "todo2.creation.service"

local M = {}

local format = require("todo2.utils.format")
local store_line = require("todo2.store.link.line")
local core = require("todo2.store.link.core")
local relation = require("todo2.store.link.relation")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")
local context = require("todo2.utils.context")
local hash = require("todo2.utils.hash")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---校验行号是否有效
---@param bufnr number 缓冲区号
---@param line number 行号
---@return boolean
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line >= 1 and line <= total
end

---从代码行提取标签和ID
---@param line string 代码行内容
---@return string?, string? 标签, ID
local function extract_code_tag_id(line)
	if not line then
		return nil, nil
	end
	local id = id_utils.extract_id_from_code_mark(line)
	local tag = id_utils.extract_tag_from_code_mark(line)
	return tag or "TODO", id
end

---提取代码上下文
---@param bufnr number 缓冲区号
---@param line number 行号
---@param filepath string 文件路径
---@return table? 上下文对象
local function extract_context(bufnr, line, filepath)
	return context.build_from_buffer(bufnr, line, filepath)
end

---校验任务是否完整写入
---@param id string 任务ID
---@param expected_data table 期望的数据
---@return boolean, string
local function verify_task_written(id, expected_data)
	local task = core.get_task(id)
	if not task then
		return false, "任务未找到"
	end

	-- 1. 校验核心数据
	if task.core.content ~= expected_data.content then
		return false,
			string.format("内容不匹配: 期望 '%s', 实际 '%s'", expected_data.content, task.core.content)
	end

	if expected_data.tag and task.core.tags[1] ~= expected_data.tag then
		return false, string.format("标签不匹配: 期望 '%s', 实际 '%s'", expected_data.tag, task.core.tags[1])
	end

	-- 2. 校验TODO位置
	if expected_data.todo_path then
		if not task.locations.todo then
			return false, "TODO位置缺失"
		end
		if task.locations.todo.path ~= expected_data.todo_path then
			return false, "TODO路径不匹配"
		end
		if task.locations.todo.line ~= expected_data.todo_line then
			return false,
				string.format(
					"TODO行号不匹配: 期望 %d, 实际 %d",
					expected_data.todo_line,
					task.locations.todo.line
				)
		end
	end

	-- 3. 校验代码位置
	if expected_data.code_path then
		if not task.locations.code then
			return false, "代码位置缺失"
		end
		if task.locations.code.path ~= expected_data.code_path then
			return false, "代码路径不匹配"
		end
		if task.locations.code.line ~= expected_data.code_line then
			return false,
				string.format(
					"代码行号不匹配: 期望 %d, 实际 %d",
					expected_data.code_line,
					task.locations.code.line
				)
		end
	end

	-- 4. 校验父子关系
	if expected_data.parent_id then
		local parent_id = relation.get_parent_id(id)
		if parent_id ~= expected_data.parent_id then
			return false,
				string.format(
					"父任务ID不匹配: 期望 '%s', 实际 '%s'",
					expected_data.parent_id,
					tostring(parent_id)
				)
		end
	end

	return true, "写入完整"
end

---创建内部任务对象
---@param id string 任务ID
---@param data table 任务数据
---@return table 任务对象
local function create_internal_task(id, data)
	local now = os.time()

	local task = {
		id = id,
		core = {
			content = data.content or "",
			content_hash = hash.hash(data.content or ""),
			status = data.status or "normal",
			tags = data.tags or { "TODO" },
			ai_executable = data.ai_executable,
			sync_status = "local",
		},
		-- 关系信息
		relations = {
			parent_id = data.parent_id,
			child_ids = {},
			level = data.level or 0,
		},
		timestamps = {
			created = now,
			updated = now,
			completed = nil,
			archived = nil,
			archived_reason = nil,
		},
		verification = {
			line_verified = true,
			last_verified_at = now,
		},
		locations = {},
	}

	-- 设置位置信息
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
-- 公开API
---------------------------------------------------------------------

---创建代码链接
---@param bufnr number 缓冲区号
---@param line number 行号
---@param id string 任务ID
---@param content? string 任务内容
---@param tag? string 标签
---@return boolean
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

	local final_content = content or "新任务"

	-- 获取或创建任务
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
			tags = { final_tag },
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

	-- 校验写入
	local ok, msg = verify_task_written(id, {
		content = final_content,
		tag = final_tag,
		code_path = path,
		code_line = line,
	})
	if not ok then
		vim.notify("代码链接创建后校验失败: " .. msg, vim.log.levels.WARN)
	end

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

---创建TODO链接
---@param path string TODO文件路径
---@param line number 行号
---@param id string 任务ID
---@param content? string 任务内容
---@param options? { tags?: string[], parent_id?: string, level?: number } 选项
---@return boolean
function M.create_todo_link(path, line, id, content, options)
	options = options or {}

	if not path or not line or not id then
		vim.notify("创建TODO链接失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	if not id_utils.is_valid(id) then
		vim.notify("创建TODO链接失败：ID格式无效 " .. id, vim.log.levels.ERROR)
		return false
	end

	local final_content = content or "新任务"
	local tags = options.tags or { "TODO" }

	local existing = core.get_task(id)
	if existing then
		existing.locations.todo = {
			path = path,
			line = line,
		}
		existing.core.content = final_content
		existing.core.tags = tags
		-- 如果有父任务ID，更新relations
		if options.parent_id then
			existing.relations = existing.relations or {}
			existing.relations.parent_id = options.parent_id
			existing.relations.level = options.level or 0
		end
		existing.timestamps.updated = os.time()
		core.save_task(id, existing)
	else
		local task_data = {
			content = final_content,
			tags = tags,
			type = "todo",
			path = path,
			line = line,
			parent_id = options.parent_id,
			level = options.level or 0,
		}
		local task = create_internal_task(id, task_data)
		core.save_task(id, task)
	end

	-- 如果有父任务，更新父任务的child_ids
	if options.parent_id then
		local parent = core.get_task(options.parent_id)
		if parent then
			parent.relations = parent.relations or {}
			parent.relations.child_ids = parent.relations.child_ids or {}
			if not vim.tbl_contains(parent.relations.child_ids, id) then
				table.insert(parent.relations.child_ids, id)
				core.save_task(options.parent_id, parent)
			end
		end
	end

	-- 更新索引
	local index = require("todo2.store.index")
	index._add_id_to_file_index("todo.index.file_to_todo", path, id)

	-- 校验写入
	local ok, msg = verify_task_written(id, {
		content = final_content,
		tag = tags[1],
		todo_path = path,
		todo_line = line,
		parent_id = options.parent_id,
	})
	if not ok then
		vim.notify("TODO链接创建后校验失败: " .. msg, vim.log.levels.WARN)
	end

	events.on_state_changed({
		source = "create_todo_link",
		file = path,
		ids = { id },
	})

	return true
end

---插入任务行到TODO文件
---@param bufnr number 缓冲区号
---@param lnum number 插入位置（0-based）
---@param options { indent?: string, checkbox?: string, id?: string, content?: string, update_store?: boolean, trigger_event?: boolean, autosave?: boolean, event_source?: string }
---@return number? 新行号
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

	if opts.id and not id_utils.is_valid(opts.id) then
		vim.notify("插入任务行失败：ID格式无效 " .. opts.id, vim.log.levels.ERROR)
		return nil
	end

	-- 格式化任务行（不包含tag，tag由存储管理）
	local line_content = format.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		content = opts.content,
	})

	local ok, result_or_err = pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { line_content })
		local new_line = lnum + 1

		if store_line.link and store_line.link.handle_line_shift then
			store_line.link.handle_line_shift(bufnr, new_line, 1)
		end

		if opts.update_store and opts.id then
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path ~= "" then
				local success = M.create_todo_link(path, new_line, opts.id, opts.content)
				if not success then
					error("创建TODO链接失败")
				end
			end
		end

		return new_line, line_content
	end)

	if not ok then
		vim.notify("插入任务行失败：" .. tostring(result_or_err), vim.log.levels.ERROR)
		return nil
	end

	local new_line = result_or_err

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

	return new_line
end

---插入任务到TODO文件
---@param todo_path string TODO文件路径
---@param id string 任务ID
---@param task_content? string 任务内容
---@return number? 新行号
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

---创建子任务
---@param parent_bufnr number 父任务缓冲区号
---@param parent_task table 父任务对象（来自parser）
---@param child_id string 子任务ID
---@param content? string 子任务内容
---@param tag? string 标签
---@return number? 子任务行号
function M.create_child_task(parent_bufnr, parent_task, child_id, content, tag)
	if not id_utils.is_valid(child_id) then
		vim.notify("创建子任务失败：ID格式无效 " .. child_id, vim.log.levels.ERROR)
		return nil
	end

	content = content or "子任务"
	tag = tag or "TODO"

	local parent_indent = string.rep("  ", parent_task.level or 0)
	local child_indent = parent_indent .. "  "
	local parent_id = parent_task.id
	local path = vim.api.nvim_buf_get_name(parent_bufnr)

	-- 1. 插入TODO行
	local new_line = M.insert_task_line(parent_bufnr, parent_task.line_num, {
		indent = child_indent,
		id = child_id,
		content = content,
		update_store = false, -- 暂时不更新存储，等建立关系后再更新
		event_source = "create_child_task",
	})

	if not new_line then
		return nil
	end

	-- 2. 创建TODO链接（包含父子关系）
	local success = M.create_todo_link(path, new_line, child_id, content, {
		tags = { tag },
		parent_id = parent_id,
		level = (parent_task.level or 0) + 1,
	})

	if not success then
		vim.notify("创建子任务失败：无法创建TODO链接", vim.log.levels.ERROR)
		return nil
	end

	-- 3. 校验写入
	local ok, msg = verify_task_written(child_id, {
		content = content,
		tag = tag,
		todo_path = path,
		todo_line = new_line,
		parent_id = parent_id,
	})

	if not ok then
		vim.notify("子任务创建后校验失败: " .. msg, vim.log.levels.WARN)
	end

	return new_line
end

return M
