-- lua/todo2/store/link/offset.lua
-- 行号偏移管理模块：处理行号偏移和代码块移动

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local query = require("todo2.store.link.query")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")

---------------------------------------------------------------------
-- 公开 API
---------------------------------------------------------------------

--- 批量偏移行号（全局模式）
---@param path string 文件路径
---@param start_line number 起始行号
---@param offset number 偏移量（正数向下，负数向上）
---@param opts? { skip_archived?: boolean, dry_run?: boolean } 选项
---@return { updated: number, affected_ids: string[] }
function M.shift_lines(path, start_line, offset, opts)
	opts = opts or {}
	path = file.normalize_path(path)

	if not path or path == "" or offset == 0 then
		return { updated = 0, affected_ids = {} }
	end

	local file_tasks = query.find_by_file(path)
	local affected_ids = {}
	local updated_count = 0

	-- 处理 TODO 位置
	for id, task in pairs(file_tasks.todo) do
		if task.locations.todo and task.locations.todo.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue
			end

			if not opts.dry_run then
				local new_line = task.locations.todo.line + offset
				if new_line < 1 then
					new_line = 1
				end
				task.locations.todo.line = new_line
				task.timestamps.updated = os.time()
				task.verified = false
				task.verification = task.verification or {}
				task.verification.line_verified = false
				core.save_task(id, task)
			end

			table.insert(affected_ids, id)
			updated_count = updated_count + 1
		end
		::continue::
	end

	-- 处理 CODE 位置
	for id, task in pairs(file_tasks.code) do
		if task.locations.code and task.locations.code.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue_code
			end

			if not opts.dry_run then
				local new_line = task.locations.code.line + offset
				if new_line < 1 then
					new_line = 1
				end
				task.locations.code.line = new_line
				task.timestamps.updated = os.time()
				task.verified = false
				task.verification = task.verification or {}
				task.verification.line_verified = false
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

--- 自动处理行号偏移（编辑器触发）
---@param bufnr number 缓冲区号
---@param start_line number 起始行号
---@param offset number 偏移量
---@return boolean 是否更新了任何任务
function M.handle_line_shift(bufnr, start_line, offset)
	local path = buffer.get_path(bufnr)
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

return M
