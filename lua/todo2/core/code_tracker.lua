-- lua/todo2/core/code_tracker.lua
-- 代码文件行号追踪：当代码文件发生行号变化（插入/删除行）时，
-- 同步更新存储中代码标记（locations.code.line），使标记始终跟随代码。

local M = {}

local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local offset = require("todo2.store.link.offset")
local query = require("todo2.store.link.query")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 内部状态
---------------------------------------------------------------------
local attached = {}

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

	local delta = new_lastline - lastline
	if delta == 0 then
		return
	end

	local path = buffer.get_path(buf)
	if path == "" or file.is_todo_file(path) then
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
