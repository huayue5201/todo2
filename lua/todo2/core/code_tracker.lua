-- lua/todo2/core/code_tracker.lua
-- 代码文件行号追踪：当代码文件发生行号变化（插入/删除行）时，
-- 同步更新存储中代码标记（locations.code.line），使标记始终跟随代码。

local M = {}

local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local offset = require("todo2.store.task.offset")
local query = require("todo2.store.task.query")
local core = require("todo2.store.task.core")
local code_block = require("todo2.code_block")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local attached = {}
local refresh_timers = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---对变更区域内的代码标记尝试内容匹配重定位，失败则标记为“未验证”
---@param path string 文件路径
---@param firstline number 0-indexed 起始行（含）
---@param lastline number 0-indexed 结束行（不含）
---@param lines string[] 当前文件行内容
local function relocate_region(path, firstline, lastline, lines)
	local file_tasks = query.find_by_file(path)

	for id, task in pairs(file_tasks.code) do
		local loc = task.locations and task.locations.code
		if loc then
			local l0 = loc.line - 1
			if l0 >= firstline and l0 < lastline then
				local ok = core.relocate_code_location(id, lines)
				if not ok then
					task.verification = task.verification or {}
					task.verification.line_verified = false
					task.timestamps = task.timestamps or {}
					task.timestamps.updated = os.time()
					core.save_task(id, task)
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- 上下文刷新：函数重命名后重新解析标记所在代码块
---------------------------------------------------------------------

local function stop_refresh_timer(bufnr)
	local timer = refresh_timers[bufnr]
	if timer then
		pcall(function()
			timer:stop()
			timer:close()
		end)
		refresh_timers[bufnr] = nil
	end
end

---重新解析单个代码标记的上下文，并在变化时写回存储。
---@param bufnr number
---@param target { id:string, task:table, loc:table }
local function refresh_one_context(bufnr, target)
	local loc = target.loc
	local line = loc.line

	code_block.get_block_at_line_async(bufnr, line, function(block)
		if not block then
			return
		end

		local old = loc.context
		local new_ctx = block

		-- 保留旧上下文中新块未提供的字段（如 relative_line）
		if old and new_ctx.relative_line == nil and old.relative_line ~= nil then
			new_ctx.relative_line = old.relative_line
		end

		-- 仅在新块提供了对应字段且内容变化时写回，
		-- 避免用信息更少的降级结果（如 indent 块）覆盖原有上下文
		local changed = false
		if not old then
			changed = true
		else
			local sig_changed = new_ctx.signature ~= nil
				and new_ctx.signature ~= ""
				and new_ctx.signature ~= old.signature
			local name_changed = new_ctx.name ~= nil
				and new_ctx.name ~= ""
				and new_ctx.name ~= old.name
			local rel_changed = new_ctx.relative_line ~= nil
				and old.relative_line ~= nil
				and new_ctx.relative_line ~= old.relative_line
			if sig_changed or name_changed or rel_changed then
				changed = true
			end
		end

		if changed then
			loc.context = code_block.to_context(new_ctx)
			loc.context_updated_at = os.time()
			target.task.timestamps = target.task.timestamps or {}
			target.task.timestamps.updated = os.time()
			core.save_task(target.id, target.task)
		end
	end)
end

---重新解析缓冲区中所有代码标记的上下文（函数名/签名等）。
---带 300ms 防抖，避免输入过程中频繁触发。
---@param bufnr number 缓冲区号
function M.refresh_contexts(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local path = buffer.get_path(bufnr)
	if path == "" or file.is_todo_file(path) then
		return
	end

	stop_refresh_timer(bufnr)

	refresh_timers[bufnr] = vim.defer_fn(function()
		refresh_timers[bufnr] = nil

		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		local file_tasks = query.find_by_file(path)
		local targets = {}

		for id, task in pairs(file_tasks.code) do
			local loc = task.locations and task.locations.code
			if loc and loc.line and loc.line >= 1 then
				targets[#targets + 1] = { id = id, task = task, loc = loc }
			end
		end

		for _, target in ipairs(targets) do
			refresh_one_context(bufnr, target)
		end
	end, 300)
end

---------------------------------------------------------------------
-- on_lines 回调
---------------------------------------------------------------------

---@param event string 事件名（"lines"）
---@param buf number 缓冲区号
---@param changedtick number
---@param firstline number 0-indexed 变更起始行（含）
---@param lastline number 0-indexed 旧变更结束行（不含）
---@param new_lastline number 0-indexed 新变更结束行（不含）
local function on_lines(event, buf, changedtick, firstline, lastline, new_lastline)
	if event ~= "lines" then
		return
	end

	local path = buffer.get_path(buf)
	if path == "" or file.is_todo_file(path) then
		return
	end

	-- 任何代码变更（含重命名等不改变行数的场景）都刷新上下文，
	-- 避免函数重命名后标记上下文过期、后续行号漂移时无法重定位
	M.refresh_contexts(buf)

	local delta = new_lastline - lastline
	if delta == 0 then
		return
	end

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		-- 变更区域下方的标记整体平移 delta
		offset.shift_lines(path, lastline + 1, delta, { skip_archived = false })

		-- 变更区域内部的标记尝试内容匹配重定位
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		relocate_region(path, firstline, lastline, lines)
	end)
end

---------------------------------------------------------------------
-- 缓冲区附加
---------------------------------------------------------------------

local function attach(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or attached[bufnr] then
		return
	end

	local path = buffer.get_path(bufnr)
	if path == "" or file.is_todo_file(path) then
		return
	end

	attached[bufnr] = true
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = on_lines,
		on_detach = function()
			attached[bufnr] = nil
			stop_refresh_timer(bufnr)
		end,
	})
end

---手动附加到指定缓冲区
---@param bufnr number 缓冲区号
function M.attach_buffer(bufnr)
	attach(bufnr)
end

---------------------------------------------------------------------
-- 保存后重新校验
---------------------------------------------------------------------

---文件保存后，对未验证的代码标记做内容匹配重定位
local function setup_reverify_on_write()
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			local path = buffer.get_path(buf)
			if path == "" or file.is_todo_file(path) then
				return
			end

			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end

				-- 保存后刷新上下文（函数重命名后同步最新签名/名称）
				M.refresh_contexts(buf)

				local file_tasks = query.find_by_file(path)
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

				for id, task in pairs(file_tasks.code) do
					local verified = task.verification and task.verification.line_verified
					if not verified then
						core.relocate_code_location(id, lines)
					end
				end
			end)
		end,
	})
end

---初始化自动追踪
function M.setup()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
		pattern = "*",
		callback = function(args)
			vim.schedule(function()
				attach(args.buf)
			end)
		end,
	})

	setup_reverify_on_write()
end

return M
