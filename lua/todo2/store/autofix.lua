-- lua/todo2/store/autofix.lua
-- 纯功能平移：只将旧接口换成新接口，逻辑完全不变

local M = {}

local core = require("todo2.store.link.core")
local locator = require("todo2.store.locator")
local archive = require("todo2.store.link.archive")

---------------------------------------------------------------------
-- 白名单
---------------------------------------------------------------------
local WHITELIST = {}

function M.add_whitelist(id)
	WHITELIST[id] = true
end

function M.remove_whitelist(id)
	WHITELIST[id] = nil
end

local function is_whitelisted(id)
	return WHITELIST[id] == true
end

---------------------------------------------------------------------
-- 1) 行号修复：使用 locator 精准定位
---------------------------------------------------------------------
local function fix_line_number(id)
	if is_whitelisted(id) then
		return false
	end

	local task = core.get_task(id)
	if not task then
		return false
	end

	local fixed = false

	-- 修复 TODO 位置
	if task.locations.todo then
		-- 构造兼容的 link 对象给 locator
		local link_obj = {
			id = id,
			path = task.locations.todo.path,
			line = task.locations.todo.line,
			content = task.core.content,
			tag = task.core.tags[1],
			content_hash = task.core.content_hash,
			type = "todo_to_code",
		}

		local located = locator.locate_task_sync(link_obj)
		if located and located.line and located.line ~= task.locations.todo.line then
			task.locations.todo.line = located.line
			task.verification.line_verified = true
			task.timestamps.updated = os.time()
			fixed = true
		end
	end

	-- 修复 CODE 位置
	if task.locations.code then
		local link_obj = {
			id = id,
			path = task.locations.code.path,
			line = task.locations.code.line,
			content = task.core.content,
			tag = task.core.tags[1],
			content_hash = task.core.content_hash,
			context = task.locations.code.context,
			type = "code_to_todo",
		}

		local located = locator.locate_task_sync(link_obj)
		if located and located.line and located.line ~= task.locations.code.line then
			task.locations.code.line = located.line
			task.verification.line_verified = true
			task.timestamps.updated = os.time()
			fixed = true
		end
	end

	if fixed then
		core.save_task(id, task)
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 2) 悬挂删除：TODO 和 CODE 都不存在 → 删除存储
---------------------------------------------------------------------
local function delete_dangling(id)
	if is_whitelisted(id) then
		return false
	end

	local task = core.get_task(id)
	if not task then
		return false
	end

	-- 检查 TODO 是否存在
	local todo_exists = false
	if task.locations.todo then
		if vim.fn.filereadable(task.locations.todo.path) == 1 then
			local lines = vim.fn.readfile(task.locations.todo.path)
			if lines and #lines > 0 and task.locations.todo.line <= #lines then
				local line = lines[task.locations.todo.line]
				if line and line:match("ref:" .. id) then
					todo_exists = true
				end
			end
		end
	end

	-- 检查 CODE 是否存在
	local code_exists = false
	if task.locations.code then
		if vim.fn.filereadable(task.locations.code.path) == 1 then
			local lines = vim.fn.readfile(task.locations.code.path)
			if lines and #lines > 0 and task.locations.code.line <= #lines then
				local line = lines[task.locations.code.line]
				if line and line:match("ref:" .. id) then
					code_exists = true
				end
			end
		end
	end

	-- 如果两个都不存在，删除
	if not todo_exists and not code_exists then
		-- 删除快照
		local snapshot = archive.get_archive_snapshot(id)
		if snapshot then
			archive.delete_archive_snapshot(id)
		end

		-- 删除任务
		core.delete_task(id)
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 3) TODO 删除 → 删除 CODE + 存储
---------------------------------------------------------------------
local function delete_if_todo_missing(id)
	if is_whitelisted(id) then
		return false
	end

	local task = core.get_task(id)
	if not task then
		return false
	end

	-- 检查 TODO 是否存在
	local todo_exists = false
	if task.locations.todo then
		if vim.fn.filereadable(task.locations.todo.path) == 1 then
			local lines = vim.fn.readfile(task.locations.todo.path)
			if lines and #lines > 0 and task.locations.todo.line <= #lines then
				local line = lines[task.locations.todo.line]
				if line and line:match("ref:" .. id) then
					todo_exists = true
				end
			end
		end
	end

	-- TODO 不存在，但 CODE 存在 → 删除整个任务
	if not todo_exists and task.locations.code then
		local snapshot = archive.get_archive_snapshot(id)
		if snapshot then
			archive.delete_archive_snapshot(id)
		end

		core.delete_task(id)
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 主修复入口：对所有 ID 执行三类修复
---------------------------------------------------------------------
function M.run_full_repair()
	-- 获取所有内部任务ID
	local store = require("todo2.store.nvim_store")
	local prefix = "todo.links.internal."
	local keys = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local all_ids = {}

	for _, key in ipairs(keys) do
		local id = key:match("todo%.links%.internal%.(.*)$")
		if id then
			table.insert(all_ids, id)
		end
	end

	local report = {
		line_fixed = 0,
		dangling_deleted = 0,
		todo_deleted_cleanup = 0,
	}

	for _, id in ipairs(all_ids) do
		if not is_whitelisted(id) then
			-- 行号修复
			if fix_line_number(id) then
				report.line_fixed = report.line_fixed + 1
			end

			-- 悬挂删除
			if delete_dangling(id) then
				report.dangling_deleted = report.dangling_deleted + 1
			end

			-- TODO 删除 → 删除 CODE
			if delete_if_todo_missing(id) then
				report.todo_deleted_cleanup = report.todo_deleted_cleanup + 1
			end
		end
	end

	return report
end

---------------------------------------------------------------------
-- 定期修复
---------------------------------------------------------------------
function M.setup_periodic_repair()
	local timer = vim.loop.new_timer()
	timer:start(0, 10 * 60 * 1000, function()
		vim.schedule(function()
			M.run_full_repair()
		end)
	end)
end

return M
