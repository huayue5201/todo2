-- lua/todo2/task/deleter.lua
-- 纯功能平移：使用新接口获取任务数据

local M = {}

local id_utils = require("todo2.utils.id")
local line_analyzer = require("todo2.utils.line_analyzer")
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local locator = require("todo2.store.locator")
local scheduler = require("todo2.render.scheduler")
local autosave = require("todo2.core.autosave")

---------------------------------------------------------------------
-- 工具：从任务构造兼容的 link 对象（用于 locator）
---------------------------------------------------------------------
local function task_to_link(task, location_type)
	if not task then
		return nil
	end

	if location_type == "todo" and task.locations.todo then
		return {
			id = task.id,
			path = task.locations.todo.path,
			line = task.locations.todo.line,
			content = task.core.content,
			tag = task.core.tags[1],
			type = "todo_to_code",
		}
	elseif location_type == "code" and task.locations.code then
		return {
			id = task.id,
			path = task.locations.code.path,
			line = task.locations.code.line,
			content = task.core.content,
			tag = task.core.tags[1],
			context = task.locations.code.context,
			type = "code_to_todo",
		}
	end
	return nil
end

---------------------------------------------------------------------
-- 工具：读取行内容
---------------------------------------------------------------------
local function read_line(filepath, lnum)
	local lines = scheduler.get_file_lines(filepath)
	return lines and lines[lnum] or nil
end

---------------------------------------------------------------------
-- 工具：验证行是否包含指定ID
---------------------------------------------------------------------
local function line_contains_id(filepath, lnum, id)
	local line = read_line(filepath, lnum)
	return line and id_utils.extract_id(line) == id
end

---------------------------------------------------------------------
-- 工具：获取正确的行号（locator兜底）
---------------------------------------------------------------------
local function resolve_line(link_obj)
	if not link_obj then
		return nil
	end

	local located = locator.locate_task_sync(link_obj)
	if located and located.line then
		return located.line
	end

	if link_obj.line then
		return link_obj.line
	end

	return nil
end

---------------------------------------------------------------------
-- 工具：删除文件中的行
---------------------------------------------------------------------
local function delete_file_lines(filepath, lines_to_delete)
	if not filepath or not lines_to_delete or #lines_to_delete == 0 then
		return 0
	end

	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	table.sort(lines_to_delete, function(a, b)
		return a > b
	end)

	for _, lnum in ipairs(lines_to_delete) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, lnum - 1, lnum, false, {})
	end

	autosave.request_save(bufnr)

	return #lines_to_delete
end

---------------------------------------------------------------------
-- 核心：根据ID彻底删除（三位一体）
---------------------------------------------------------------------
function M.delete_by_id(id)
	if not id or not id_utils.is_valid(id) then
		vim.notify("删除失败：ID格式无效", vim.log.levels.ERROR)
		return false, { id = id, error = "invalid_id" }
	end

	local result = {
		id = id,
		todo_line_deleted = false,
		code_line_deleted = false,
		store_deleted = false,
		lines_deleted = {},
	}

	-- 1. 获取任务数据
	local task = core.get_task(id)

	-- 如果不存在，直接返回成功（幂等）
	if not task then
		return true, result
	end

	-- 2. 尝试删除TODO行（如果存在）
	if task.locations.todo then
		local link_obj = task_to_link(task, "todo")
		local todo_line = resolve_line(link_obj)
		if todo_line then
			local deleted = delete_file_lines(task.locations.todo.path, { todo_line })
			if deleted > 0 then
				result.todo_line_deleted = true
				table.insert(result.lines_deleted, {
					path = task.locations.todo.path,
					line = todo_line,
					type = "todo",
				})
			end
		end
	end

	-- 3. 尝试删除CODE行（如果存在）
	if task.locations.code then
		local link_obj = task_to_link(task, "code")
		local code_line = resolve_line(link_obj)
		if code_line then
			local deleted = delete_file_lines(task.locations.code.path, { code_line })
			if deleted > 0 then
				result.code_line_deleted = true
				table.insert(result.lines_deleted, {
					path = task.locations.code.path,
					line = code_line,
					type = "code",
				})
			end
		end
	end

	-- 4. 删除存储数据
	local archive = require("todo2.store.link.archive")
	if archive.get_archive_snapshot(id) then
		archive.delete_archive_snapshot(id)
	end

	-- 删除内部任务
	core.delete_task(id)

	-- ⭐ 修复：使用 index 模块内部定义的常量
	-- 清理索引
	if task.locations.todo then
		pcall(index._remove_id_from_file_index, "todo.index.file_to_todo", task.locations.todo.path, id)
		-- 或者更好的方式：使用常量（如果 index 模块导出了）
		-- pcall(index._remove_id_from_file_index, index.NS.TODO, task.locations.todo.path, id)
	end
	if task.locations.code then
		pcall(index._remove_id_from_file_index, "todo.index.file_to_code", task.locations.code.path, id)
		-- pcall(index._remove_id_from_file_index, index.NS.CODE, task.locations.code.path, id)
	end

	result.store_deleted = true

	-- 5. 触发事件
	local events = require("todo2.core.events")
	events.on_state_changed({
		source = "delete_by_id",
		ids = { id },
	})

	if result.todo_line_deleted or result.code_line_deleted or result.store_deleted then
		vim.notify(string.format("✅ 已删除ID %s", id:sub(1, 6)), vim.log.levels.INFO)
	end

	return true, result
end

---------------------------------------------------------------------
-- 批量删除
---------------------------------------------------------------------
function M.delete_by_ids(ids)
	if not ids or #ids == 0 then
		return false, { error = "no_ids" }
	end

	local results = {
		total = #ids,
		succeeded = 0,
		failed = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local ok, res = M.delete_by_id(id)
		if ok then
			results.succeeded = results.succeeded + 1
			table.insert(results.details, { id = id, success = true, result = res })
		else
			results.failed = results.failed + 1
			table.insert(results.details, { id = id, success = false, error = res.error })
		end
	end

	vim.notify(
		string.format("删除完成：%d成功，%d失败", results.succeeded, results.failed),
		results.failed == 0 and vim.log.levels.INFO or vim.log.levels.WARN
	)

	return results.succeeded > 0, results
end

---------------------------------------------------------------------
-- 删除当前行的代码标记
---------------------------------------------------------------------
function M.delete_current_code_mark()
	local analysis = line_analyzer.analyze_current_line()

	if not analysis.is_code_mark or not analysis.id then
		vim.notify("当前行不是代码标记", vim.log.levels.WARN)
		return false
	end

	return M.delete_by_id(analysis.id)
end

---------------------------------------------------------------------
-- 兼容handlers.lua的接口
---------------------------------------------------------------------
function M.delete_code_link()
	return M.delete_current_code_mark()
end

function M.delete_todo_task_line(id)
	return M.delete_by_id(id)
end

function M.batch_delete_todo_links(ids)
	return M.delete_by_ids(ids)
end

return M
