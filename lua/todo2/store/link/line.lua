-- lua/todo2/store/link/line.lua
-- 行号偏移管理

-- DEBUG:ref:fda5a7
local M = {}

local index = require("todo2.store.index")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 批量偏移行号
---------------------------------------------------------------------
function M.shift_lines(path, start_line, offset, opts)
	opts = opts or {}
	path = index._normalize_path(path)

	if not path or path == "" or offset == 0 then
		return { updated = 0, affected_ids = {} }
	end

	-- 获取文件中的所有链接
	local file_todo_ids = index.find_todo_links_by_file(path) or {}
	local file_code_ids = index.find_code_links_by_file(path) or {}

	local todo_ids = {}
	for _, link in ipairs(file_todo_ids) do
		table.insert(todo_ids, link.id)
	end

	local code_ids = {}
	for _, link in ipairs(file_code_ids) do
		table.insert(code_ids, link.id)
	end

	local affected_ids = {}
	local updated_count = 0

	-- 处理TODO链接
	for _, id in ipairs(todo_ids) do
		local link = core.get_todo(id, { verify_line = false })
		if link and link.line >= start_line then
			if opts.skip_archived and link.status == types.STATUS.ARCHIVED then
				goto continue_todo
			end

			if not opts.dry_run then
				link.line = link.line + offset
				link.updated_at = os.time()
				link.line_verified = false
				core.update_todo(id, link)
			end

			table.insert(affected_ids, id)
			updated_count = updated_count + 1
		end
		::continue_todo::
	end

	-- 处理代码链接
	for _, id in ipairs(code_ids) do
		local link = core.get_code(id, { verify_line = false })
		if link and link.line >= start_line then
			if opts.skip_archived and link.status == types.STATUS.ARCHIVED then
				goto continue_code
			end

			if not opts.dry_run then
				link.line = link.line + offset
				link.updated_at = os.time()
				link.line_verified = false
				core.update_code(id, link)
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
function M.handle_line_shift(bufnr, start_line, offset)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false
	end

	local result = M.shift_lines(path, start_line, offset, {
		skip_archived = true,
	})

	if result.updated > 0 then
		-- 触发事件
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
