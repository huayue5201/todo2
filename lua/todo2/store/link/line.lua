-- lua/todo2/store/link/line.lua
-- 行号管理模块：处理行号偏移和批量操作

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local query = require("todo2.store.link.query")
local file = require("todo2.utils.file") -- ⭐ 引入文件工具模块

---------------------------------------------------------------------
-- 批量偏移行号
---------------------------------------------------------------------

---批量偏移行号
---@param path string 文件路径
---@param start_line number 起始行号
---@param offset number 偏移量（正数向下，负数向上）
---@param opts? { skip_archived?: boolean, dry_run?: boolean } 选项
---@return { updated: number, affected_ids: string[] } 更新结果
function M.shift_lines(path, start_line, offset, opts)
	opts = opts or {}
	path = file.normalize_path(path) -- ⭐ 使用文件工具模块

	if not path or path == "" or offset == 0 then
		return { updated = 0, affected_ids = {} }
	end

	-- 获取文件中的所有任务
	local file_tasks = query.find_by_file(path)
	local affected_ids = {}
	local updated_count = 0

	-- 处理TODO位置
	for id, task in pairs(file_tasks.todo) do
		if task.locations.todo.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue
			end

			if not opts.dry_run then
				task.locations.todo.line = task.locations.todo.line + offset
				task.timestamps.updated = os.time()
				task.verified = false -- ⭐ 使用简化后的字段
				core.save_task(id, task)
			end

			table.insert(affected_ids, id)
			updated_count = updated_count + 1
		end
		::continue::
	end

	-- 处理CODE位置
	for id, task in pairs(file_tasks.code) do
		if task.locations.code.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue_code
			end

			if not opts.dry_run then
				task.locations.code.line = task.locations.code.line + offset
				task.timestamps.updated = os.time()
				task.verified = false -- ⭐ 使用简化后的字段
				core.save_task(id, task)
			end

			if not vim.tbl_contains(affected_ids, id) then
				table.insert(affected_ids, id)
				updated_count = updated_count + 1
			end
		end
		::continue_code::
	end

	return {
		updated = updated_count,
		affected_ids = affected_ids,
	}
end

---------------------------------------------------------------------
-- 自动处理行号偏移
---------------------------------------------------------------------

---自动处理行号偏移
---@param bufnr number 缓冲区号
---@param start_line number 起始行号
---@param offset number 偏移量
---@return boolean 是否更新了任何任务
function M.handle_line_shift(bufnr, start_line, offset)
	local path = file.buf_path(bufnr) -- ⭐ 使用文件工具模块
	if path == "" then
		return false
	end

	local result = M.shift_lines(path, start_line, offset, {
		skip_archived = true,
	})

	if result.updated > 0 then
		local events = require("todo2.core.events")
		if events then
			events.on_state_changed({
				source = "line_shift",
				file = path,
				bufnr = bufnr,
				ids = result.affected_ids,
				shift_offset = offset,
				timestamp = os.time() * 1000,
			})
		end
	end

	return result.updated > 0
end

---------------------------------------------------------------------
-- 获取某行的任务
---------------------------------------------------------------------

---获取某行的任务
---@param path string 文件路径
---@param line number 行号
---@return table[] 任务对象数组
function M.get_task_at_line(path, line)
	path = file.normalize_path(path) -- ⭐ 使用文件工具模块
	local file_tasks = query.find_by_file(path)
	local result = {}

	for _, task in pairs(file_tasks.todo) do
		if task.locations.todo.line == line then
			table.insert(result, task)
		end
	end

	for _, task in pairs(file_tasks.code) do
		if task.locations.code.line == line then
			table.insert(result, task)
		end
	end

	return result
end

return M
