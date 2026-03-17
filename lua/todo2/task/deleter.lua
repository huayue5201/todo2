local M = {}

local id_utils = require("todo2.utils.id")
local line_analyzer = require("todo2.utils.line_analyzer")
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local locator = require("todo2.store.locator")
local autosave = require("todo2.core.autosave")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- task → link（兼容 locator）
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
end

---------------------------------------------------------------------
-- 定位行（locator 兜底）
---------------------------------------------------------------------
local function resolve_line(link_obj)
	if not link_obj then
		return nil
	end

	local located = locator.locate_task_sync(link_obj)
	return (located and located.line) or link_obj.line
end

---------------------------------------------------------------------
-- 删除文件行
---------------------------------------------------------------------
local function delete_file_lines(filepath, lines)
	if not filepath or not lines or #lines == 0 then
		return 0
	end

	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	table.sort(lines, function(a, b)
		return a > b
	end)

	for _, lnum in ipairs(lines) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, lnum - 1, lnum, false, {})
	end

	autosave.request_save(bufnr)
	return #lines
end

---------------------------------------------------------------------
-- 核心删除
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

	-- 1. 获取任务
	local task = core.get_task(id)
	if not task then
		return true, result
	end

	-- ⭐ 提前收集文件（关键）
	local files = {}
	if task.locations.todo and task.locations.todo.path then
		table.insert(files, task.locations.todo.path)
	end
	if task.locations.code and task.locations.code.path then
		table.insert(files, task.locations.code.path)
	end

	-- 2. 删除 TODO
	if task.locations.todo then
		local line = resolve_line(task_to_link(task, "todo"))
		if line then
			if delete_file_lines(task.locations.todo.path, { line }) > 0 then
				result.todo_line_deleted = true
				table.insert(result.lines_deleted, {
					path = task.locations.todo.path,
					line = line,
					type = "todo",
				})
			end
		end
	end

	-- 3. 删除 CODE
	if task.locations.code then
		local line = resolve_line(task_to_link(task, "code"))
		if line then
			if delete_file_lines(task.locations.code.path, { line }) > 0 then
				result.code_line_deleted = true
				table.insert(result.lines_deleted, {
					path = task.locations.code.path,
					line = line,
					type = "code",
				})
			end
		end
	end

	-- ⭐ 4. 先触发事件（核心修复点）
	events.on_state_changed({
		source = "delete_by_id",
		ids = { id },
		files = files,
	})

	-- 5. 删除 archive
	local archive = require("todo2.store.link.archive")
	if archive.get_archive_snapshot(id) then
		archive.delete_archive_snapshot(id)
	end

	-- 6. 删除 store
	core.delete_task(id)

	-- 7. 清理 index
	if task.locations.todo then
		pcall(index._remove_id_from_file_index, "todo.index.file_to_todo", task.locations.todo.path, id)
	end
	if task.locations.code then
		pcall(index._remove_id_from_file_index, "todo.index.file_to_code", task.locations.code.path, id)
	end

	result.store_deleted = true

	if result.todo_line_deleted or result.code_line_deleted then
		vim.notify(("✅ 已删除ID %s"):format(id:sub(1, 6)), vim.log.levels.INFO)
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

	local ok_cnt, fail_cnt = 0, 0
	local details = {}

	for _, id in ipairs(ids) do
		local ok, res = M.delete_by_id(id)
		if ok then
			ok_cnt = ok_cnt + 1
			table.insert(details, { id = id, success = true, result = res })
		else
			fail_cnt = fail_cnt + 1
			table.insert(details, { id = id, success = false, error = res.error })
		end
	end

	vim.notify(
		("删除完成：%d成功，%d失败"):format(ok_cnt, fail_cnt),
		fail_cnt == 0 and vim.log.levels.INFO or vim.log.levels.WARN
	)

	return ok_cnt > 0, {
		total = #ids,
		succeeded = ok_cnt,
		failed = fail_cnt,
		details = details,
	}
end

---------------------------------------------------------------------
-- 当前行删除
---------------------------------------------------------------------
function M.delete_current_code_mark()
	local a = line_analyzer.analyze_current_line()
	if not a.is_code_mark or not a.id then
		vim.notify("当前行不是代码标记", vim.log.levels.WARN)
		return false
	end
	return M.delete_by_id(a.id)
end

return M
