-- lua/todo2/store/link/offset.lua
-- 行号偏移管理模块：处理行号偏移和代码块移动

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local query = require("todo2.store.link.query")
local index = require("todo2.store.index")
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

--- 收集指定行范围内的所有代码任务ID
---@param path string 文件路径
---@param start_line number 起始行
---@param end_line number 结束行
---@return string[] 任务ID列表
local function collect_task_ids_in_range(path, start_line, end_line)
	local tasks = index.find_code_links_by_file(path)
	local ids = {}

	for _, task in ipairs(tasks) do
		local line = task.locations.code.line
		if line >= start_line and line <= end_line then
			table.insert(ids, task.id)
		end
	end

	return ids
end

--- 计算新行号（通用偏移）
---@param old_line number 原行号
---@param old_start number 原起始行（用于代码块移动）
---@param new_start number 新起始行（用于代码块移动）
---@param offset number 偏移量（用于全局偏移）
---@return number
local function calculate_new_line(old_line, old_start, new_start, offset)
	if offset ~= nil then
		-- 全局偏移模式
		return old_line + offset
	else
		-- 代码块移动模式
		local offset = old_line - old_start
		return new_start + offset
	end
end

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
		if task.locations.todo.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue
			end

			if not opts.dry_run then
				task.locations.todo.line = task.locations.todo.line + offset
				task.timestamps.updated = os.time()
				task.verified = false
				core.save_task(id, task)
			end

			table.insert(affected_ids, id)
			updated_count = updated_count + 1
		end
		::continue::
	end

	-- 处理 CODE 位置
	for id, task in pairs(file_tasks.code) do
		if task.locations.code.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue_code
			end

			if not opts.dry_run then
				task.locations.code.line = task.locations.code.line + offset
				task.timestamps.updated = os.time()
				task.verified = false
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
	local path = file.buf_path(bufnr)
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

--- 计算代码块移动后的新位置（只计算，不写存储）
---@param old_path string 原文件路径
---@param new_path string 新文件路径（同文件时等于 old_path）
---@param old_start number 原起始行
---@param old_end number 原结束行
---@param new_start number 新起始行
---@return table[] 移动结果列表，每项包含 id, old_line, new_line, old_path, new_path
function M.calculate_block_move(old_path, new_path, old_start, old_end, new_start)
	local result = {}
	local ids = collect_task_ids_in_range(old_path, old_start, old_end)

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and task.locations.code then
			local old_line = task.locations.code.line
			local new_line = new_start + (old_line - old_start)

			table.insert(result, {
				id = id,
				old_line = old_line,
				new_line = new_line,
				old_path = old_path,
				new_path = new_path,
			})
		end
	end

	return result
end

--- 获取某行的任务
---@param path string 文件路径
---@param line number 行号
---@return table[] 任务对象数组
function M.get_task_at_line(path, line)
	path = file.normalize_path(path)
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
