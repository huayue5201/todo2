-- lua/todo2/creation/service.lua
-- 服务层：协调创建任务的整个过程，确保数据完整写入
---@module "todo2.creation.service"

local M = {}

local format = require("todo2.utils.format")
local offset = require("todo2.store.task.offset")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local id_utils = require("todo2.utils.id")
local index = require("todo2.store.index")
local buffer = require("todo2.utils.buffer")
local code_block = require("todo2.code_block")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

---@class InsertTaskResult
---@field line_num integer 插入后的行号
---@field content string 插入的内容
---@field id string 任务ID

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---验证行号是否有效
---@param bufnr number 缓冲区号
---@param line number 行号
---@return boolean
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local line_num = tonumber(line)
	if not line_num then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line_num >= 1 and line_num <= total
end

---------------------------------------------------------------------
-- 安全格式化（避免 string.format 报错）
---------------------------------------------------------------------

---安全转换为数字
---@param n any
---@return integer
local function safe_num(n)
	return tonumber(n) or -1
end

---------------------------------------------------------------------
-- 校验任务写入
---------------------------------------------------------------------

---验证任务是否写入正确
---@param id string 任务ID
---@param expected table 期望值
---@return boolean, string
local function verify_task_written(id, expected)
	local task = core.get_task(id)
	if not task then
		return false, "任务未找到"
	end

	-- 核心内容
	if expected.content and task.core.content ~= expected.content then
		return false, string.format("内容不匹配: 期望 '%s', 实际 '%s'", expected.content, task.core.content)
	end

	-- TODO 位置
	if expected.todo_path or expected.todo_line then
		local todo_loc = core.get_todo_location(id)
		if not todo_loc then
			return false, "TODO位置缺失"
		end
		if expected.todo_path and todo_loc.path ~= expected.todo_path then
			return false,
				string.format("TODO路径不匹配: 期望 '%s', 实际 '%s'", expected.todo_path, todo_loc.path)
		end
		if expected.todo_line and todo_loc.line ~= expected.todo_line then
			return false,
				string.format(
					"TODO行号不匹配: 期望 %d, 实际 %d",
					safe_num(expected.todo_line),
					safe_num(todo_loc.line)
				)
		end
	end

	-- 代码位置
	if expected.code_path or expected.code_line then
		local code_loc = core.get_code_location(id)
		if not code_loc then
			return false, "代码位置缺失"
		end
		if expected.code_path and code_loc.path ~= expected.code_path then
			return false,
				string.format("代码路径不匹配: 期望 '%s', 实际 '%s'", expected.code_path, code_loc.path)
		end
		if expected.code_line and code_loc.line ~= expected.code_line then
			return false,
				string.format(
					"代码行号不匹配: 期望 %d, 实际 %d",
					safe_num(expected.code_line),
					safe_num(code_loc.line)
				)
		end
	end

	-- 父子关系
	if expected.parent_id then
		local parent_id = relation.get_parent_id(id)
		if parent_id ~= expected.parent_id then
			return false,
				string.format("父任务ID不匹配: 期望 '%s', 实际 '%s'", expected.parent_id, tostring(parent_id))
		end
	end

	return true, "写入完整"
end

---------------------------------------------------------------------
-- 创建内部任务对象
---------------------------------------------------------------------

---创建内部任务对象
---@param id string 任务ID
---@param data table 任务数据
---@return table
local function create_internal_task(id, data)
	local now = os.time()
	local line_num = tonumber(data.line) or 1
	local hash = require("todo2.utils.hash").hash

	local task = {
		id = id,
		core = {
			id = id,
			content = data.content or "",
			content_hash = hash(data.content or ""),
			status = data.status or "normal",
			previous_status = nil,
			sync_status = "local",
		},
		relations = data.parent_id and { parent_id = data.parent_id } or nil,
		timestamps = {
			created = now,
			updated = now,
		},
		locations = {},
	}

	if data.type == "todo" then
		task.locations.todo = {
			path = data.path,
			line = line_num,
		}
	elseif data.type == "code" then
		task.locations.code = {
			path = data.path,
			line = line_num,
		}
	end

	return task
end

---------------------------------------------------------------------
-- 创建 TODO 链接
---------------------------------------------------------------------

---创建TODO链接
---@param path string 文件路径
---@param line number|string 行号
---@param id string 任务ID
---@param content string|nil 任务内容
---@param options table|nil 选项
---@return boolean
function M.create_todo_link(path, line, id, content, options)
	options = options or {}

	if not id_utils.is_valid(id) then
		local err_msg = "创建TODO链接失败：ID格式无效 " .. id
		vim.notify(err_msg, vim.log.levels.ERROR)
		return false
	end

	local line_num = tonumber(line)
	if not line_num or line_num < 1 then
		local err_msg = "创建TODO链接失败：行号无效"
		vim.notify(err_msg, vim.log.levels.ERROR)
		return false
	end

	local final_content = content or "新任务"
	local now = os.time()

	local existing = core.get_task(id)

	if existing then
		existing.core.content = final_content
		existing.timestamps.updated = now
		existing.locations.todo = {
			path = path,
			line = line_num,
		}
		if options.parent_id then
			existing.relations = existing.relations or {}
			existing.relations.parent_id = options.parent_id
		end
		core.save_task(id, existing)
	else
		local task = create_internal_task(id, {
			content = final_content,
			type = "todo",
			path = path,
			line = line_num,
			parent_id = options.parent_id,
		})
		core.save_task(id, task)
	end

	if options.parent_id then
		relation.set_parent_child(options.parent_id, id)
	end

	index._internal.add_todo_id(path, id)

	local verify_ok, verify_msg = verify_task_written(id, {
		content = final_content,
		todo_path = path,
		todo_line = line_num,
		parent_id = options.parent_id,
	})
	if not verify_ok then
		vim.notify("TODO链接创建后校验失败: " .. verify_msg, vim.log.levels.WARN)
	end

	-- 触发事件通知 UI 刷新
	events.emit("create_todo_link", {
		file = path,
		changed_ids = { id },
	})

	return true
end

---------------------------------------------------------------------
-- 创建代码链接（简化版：不插入标记行）
---------------------------------------------------------------------

---创建代码链接
---@param bufnr number 缓冲区号
---@param line number 行号
---@param id string 任务ID
---@param content string|nil 任务内容
---@param callback function|nil 回调函数
function M.create_code_link(bufnr, line, id, content, callback)
	callback = callback or function(success, err, result) end

	if not id_utils.is_valid(id) then
		local err_msg = "创建代码链接失败：ID格式无效 " .. id
		vim.notify(err_msg, vim.log.levels.ERROR)
		callback(false, err_msg)
		return
	end

	local line_num = tonumber(line)
	if not line_num or not validate_line_number(bufnr, line_num) then
		local err_msg = "创建代码链接失败：行号无效"
		vim.notify(err_msg, vim.log.levels.ERROR)
		callback(false, err_msg)
		return
	end

	local path = buffer.get_path(bufnr)
	if path == "" then
		local err_msg = "创建代码链接失败：无法获取文件路径"
		vim.notify(err_msg, vim.log.levels.ERROR)
		callback(false, err_msg)
		return
	end

	local final_content = content or "新任务"

	vim.schedule(function()
		code_block.get_block_at_line_async(bufnr, line_num, function(block)
			local now = os.time()
			local existing = core.get_task(id)

			if existing then
				existing.core.content = final_content
				existing.timestamps.updated = now
				existing.locations.code = {
					path = path,
					line = line_num,
					context = code_block.to_context(block),
					context_updated_at = now,
				}
				core.save_task(id, existing)
			else
				local task = create_internal_task(id, {
					content = final_content,
					type = "code",
					path = path,
					line = line_num,
				})
				task.locations.code.context = code_block.to_context(block)
				task.locations.code.context_updated_at = now
				core.save_task(id, task)
			end

			index._internal.add_code_id(path, id)

			local verify_ok, verify_msg = verify_task_written(id, {
				content = final_content,
				code_path = path,
				code_line = line_num,
			})
			if not verify_ok then
				vim.notify("代码链接创建后校验失败: " .. verify_msg, vim.log.levels.WARN)
			end

			events.emit("create_code_link", {
				file = path,
				bufnr = bufnr,
				changed_ids = { id },
			})

			if autosave then
				autosave.request_save(bufnr)
			end

			callback(true, nil, { id = id, path = path, line = line_num, context = code_block.to_context(block) })
		end)
	end)
end

---------------------------------------------------------------------
-- 插入任务行
---------------------------------------------------------------------

---插入任务行
---@param bufnr number 缓冲区号
---@param lnum number 插入位置（在行后插入）
---@param options table 选项
---@return InsertTaskResult|nil
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

	local line_num = tonumber(lnum)
	if not line_num or not validate_line_number(bufnr, line_num) then
		vim.notify("插入任务行失败：行号无效", vim.log.levels.ERROR)
		return nil
	end

	if opts.id and not id_utils.is_valid(opts.id) then
		vim.notify("插入任务行失败：ID格式无效 " .. opts.id, vim.log.levels.ERROR)
		return nil
	end

	local line_content = format.format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		content = opts.content,
	})

	local set_ok, set_err = pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, line_num, line_num, false, { line_content })
	end)

	if not set_ok then
		vim.notify("插入任务行失败：" .. tostring(set_err), vim.log.levels.ERROR)
		return nil
	end

	local new_line = line_num + 1
	offset.handle_line_shift(bufnr, new_line, 1)

	local result = {
		line_num = new_line,
		content = line_content,
		id = opts.id,
	}

	-- 创建TODO链接
	if opts.update_store and opts.id then
		local path = buffer.get_path(bufnr)
		if path ~= "" then
			local link_ok = M.create_todo_link(path, new_line, opts.id, opts.content)
			if not link_ok then
				vim.notify("创建TODO链接失败", vim.log.levels.ERROR)
				return nil
			end
		end
	else
		-- 当 update_store = false 时，手动触发事件
		if opts.trigger_event and opts.id then
			local filepath = buffer.get_path(bufnr)

			events.emit(opts.event_source, {
				file = filepath,
				bufnr = bufnr,
				changed_ids = { opts.id },
			})
		end
	end

	if opts.autosave and autosave then
		autosave.request_save(bufnr)
	end

	return result
end

---------------------------------------------------------------------
-- 创建子任务
---------------------------------------------------------------------

---创建子任务
---@param parent_bufnr number 父任务缓冲区号
---@param parent_task table 父任务对象
---@param child_id string 子任务ID
---@param content string|nil 任务内容
---@return table|nil InsertTaskResult
function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	if not id_utils.is_valid(child_id) then
		vim.notify("创建子任务失败：ID格式无效 " .. child_id, vim.log.levels.ERROR)
		return nil
	end

	content = content or "子任务"

	-- 从存储层拿父任务的真实行号
	local parent_loc = core.get_todo_location(parent_task.id)
	if not parent_loc or not parent_loc.line then
		vim.notify("创建子任务失败：无法获取父任务真实行号", vim.log.levels.ERROR)
		return nil
	end

	local real_parent_line = parent_loc.line

	-- 从存储层拿父任务的真实缩进
	local parent_line_text = buffer.get_line(parent_bufnr, real_parent_line) or ""
	local parent_indent = parent_line_text:match("^(%s*)") or ""
	local child_indent = parent_indent .. "  "

	local parent_id = parent_task.id

	-- 插入子任务行
	local result = M.insert_task_line(parent_bufnr, real_parent_line, {
		indent = child_indent,
		id = child_id,
		content = content,
		update_store = false,
		event_source = "create_child_task",
	})

	if not result then
		return nil
	end

	-- 创建 TODO 链接
	local path = buffer.get_path(parent_bufnr)
	local link_ok = M.create_todo_link(path, result.line_num, child_id, content, {
		parent_id = parent_id,
	})

	if not link_ok then
		vim.notify("创建子任务失败：无法创建TODO链接", vim.log.levels.ERROR)
		return nil
	end

	-- 校验写入
	local verify_ok, verify_msg = verify_task_written(child_id, {
		content = content,
		todo_path = path,
		todo_line = result.line_num,
		parent_id = parent_id,
	})

	if not verify_ok then
		vim.notify("子任务创建后校验失败: " .. verify_msg, vim.log.levels.WARN)
	end

	return result
end

return M
