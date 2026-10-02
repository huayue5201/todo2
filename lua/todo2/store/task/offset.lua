-- lua/todo2/store/task/offset.lua
-- 行号偏移管理模块：处理行号偏移和代码块移动

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local query = require("todo2.store.task.query")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 写入代码位置的新行号（含时间戳 / 校验标记）
---@param id string
---@param task table
---@param new_line number
local function set_code_line(id, task, new_line)
	if new_line < 1 then
		new_line = 1
	end
	task.locations.code.line = new_line
	task.timestamps.updated = os.time()
	core.set_anchor_state(task, core.ANCHOR.STALE)
	core.save_task(id, task)
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
				core.save_task(id, task)
			end

			table.insert(affected_ids, id)
			updated_count = updated_count + 1
		end
		::continue::
	end

	-- 处理 CODE 位置（失联标记的行号已不可信，不参与平移）
	for id, task in pairs(file_tasks.code) do
		if core.is_anchor_lost(task) then
			goto continue_code
		end
		if task.locations.code and task.locations.code.line >= start_line then
			if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
				goto continue_code
			end

			if not opts.dry_run then
				set_code_line(id, task, task.locations.code.line + offset)
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
			events.emit("line_shift", {
				file = path,
				bufnr = bufnr,
				ids = result.affected_ids,
				shift_offset = offset,
			})
		end
	end

	return result.updated > 0
end

--- 在单个变更区域内，用行级 diff 把旧的 0-based 行偏移映射为新的。
--- 依赖行内容对齐，因此格式化前后内容未变的行能精确跟随。
---@param old_region string[] 变更前区域内容
---@param new_region string[] 变更后区域内容
---@param rel0 number 旧区域内的 0-based 行偏移
---@return number|nil new_rel0 新区域内的 0-based 行偏移；无法确定时返回 nil
local function map_within_region(old_region, new_region, rel0)
	local ok, hunks =
		pcall(vim.diff, table.concat(old_region, "\n"), table.concat(new_region, "\n"), { result_type = "indices" })
	if not ok or type(hunks) ~= "table" then
		return nil
	end

	local lnum = rel0 + 1 -- diff 的 indices 是 1-based
	local delta = 0
	for _, h in ipairs(hunks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		if lnum < start_a then
			return lnum + delta - 1
		end
		if lnum < start_a + count_a then
			-- 落在被改写块内：只有两侧行数相同才能唯一对应
			if count_a == count_b then
				return start_b + (lnum - start_a) - 1
			end
			return nil
		end
		delta = delta + (count_b - count_a)
	end
	return lnum + delta - 1
end

--- 重映射「变更区域内部」的代码标记行号（基于行级 diff）。
--- 返回无法确定的 id，供调用方回退到内容匹配重定位。
---@param path string 文件路径
---@param firstline number 0-based 变更起始行
---@param lastline number 0-based 旧变更结束行（不含）
---@param old_region string[] 变更前区域内容
---@param new_region string[] 变更后区域内容
---@param opts? { skip_archived?: boolean }
---@return { resolved: string[], unresolved: string[] }
function M.remap_region(path, firstline, lastline, old_region, new_region, opts)
	opts = opts or {}
	local result = { resolved = {}, unresolved = {} }

	path = file.normalize_path(path)
	if not path or path == "" or not old_region or not new_region then
		return result
	end

	local file_tasks = query.find_by_file(path)
	for id, task in pairs(file_tasks.code) do
		if core.is_anchor_lost(task) then
			goto continue
		end
		local loc = task.locations and task.locations.code
		if loc and loc.line then
			local l0 = loc.line - 1
			if l0 >= firstline and l0 < lastline then
				if opts.skip_archived and task.core.status == types.STATUS.ARCHIVED then
					goto continue
				end

				local new_rel = map_within_region(old_region, new_region, l0 - firstline)
				if new_rel then
					set_code_line(id, task, firstline + new_rel + 1)
					table.insert(result.resolved, id)
				else
					table.insert(result.unresolved, id)
				end
			end
		end
		::continue::
	end

	return result
end

return M
