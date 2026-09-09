-- lua/todo2/autocmds.lua
-- 统一事件处理：TODO 文件 + 代码文件渲染

local M = {}

local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")
local core = require("todo2.store.link.core")
local format = require("todo2.utils.format")
local sync = require("todo2.core.sync")
local conceal = require("todo2.render.conceal")
local buffer = require("todo2.utils.buffer")
local code_render = require("todo2.render.code_render")

local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })
local debounce_timers = {}

local function stop_timer(timer)
	if timer then
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end
end

--- 扫描 TODO 文件中的所有任务 ID
---@param bufnr number
---@return string[]
local function scan_todo_ids(bufnr)
	local ids = {}
	local lines = buffer.get_lines(bufnr)

	for _, line in ipairs(lines) do
		local id = id_utils.extract_id_from_line(line)
		if id then
			ids[id] = true
		end
	end

	local result = {}
	for id in pairs(ids) do
		table.insert(result, id)
	end
	return result
end

--- 判断是否为 TODO 文件
---@param path string
---@return boolean
local function is_todo_file(path)
	return path:match("%.todo%.md$") or path:match("%.todo$")
end

--- 文件打开时统一渲染
function M.setup_initial_render()
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)

			vim.defer_fn(function()
				if not buffer.is_valid(buf) then
					return
				end

				if is_todo_file(path) then
					events.on_state_changed({
						source = "initial_render",
						file = path,
						bufnr = buf,
						changed_ids = scan_todo_ids(buf),
					})
					conceal.apply_buffer_conceal(buf)
				else
					code_render.render_file(buf)
				end
			end, 50)
		end,
	})
end

--- 文本变更时同步存储（仅 TODO 文件，仅同步内容不同步 checkbox）
function M.setup_text_change()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		pattern = "*.todo,*.todo.md",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(0)
			if not cursor then
				return
			end

			local line_num = cursor[1]
			local line = buffer.get_line(buf, line_num)
			if not line or line == "" then
				return
			end

			local parsed = format.parse_task_line(line)
			local changed_ids = {}

			if parsed and parsed.id then
				local task = core.get_task(parsed.id)
				if task then
					if parsed.content and parsed.content ~= task.core.content then
						core.update_content(parsed.id, parsed.content)
						table.insert(changed_ids, parsed.id)
					end
				end
			end

			if #changed_ids > 0 then
				events.on_state_changed({
					source = "todo_edit",
					file = path,
					bufnr = buf,
					changed_ids = changed_ids,
				})
			end

			conceal.apply_smart_conceal(buf, { line_num })
		end,
	})
end

--- 文件保存前同步（仅 TODO 文件）
function M.setup_write_pre()
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = augroup,
		pattern = "*.todo,*.todo.md",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			stop_timer(debounce_timers[buf])

			debounce_timers[buf] = vim.loop.new_timer()
			debounce_timers[buf]:start(
				300,
				0,
				vim.schedule_wrap(function()
					if buffer.is_valid(buf) then
						local result = sync.sync_todo_file(path)
						if #result.changed_ids > 0 then
							events.on_state_changed({
								source = "todo_sync",
								file = path,
								bufnr = buf,
								changed_ids = result.changed_ids,
							})
							conceal.apply_buffer_conceal(buf)
						end
					end
					debounce_timers[buf] = nil
				end)
			)
		end,
	})
end

--- 文件保存后刷新（所有文件）
function M.setup_write_post()
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)

			vim.defer_fn(function()
				if not buffer.is_valid(buf) then
					return
				end

				if is_todo_file(path) then
					events.on_state_changed({
						source = "todo_save",
						file = path,
						bufnr = buf,
						changed_ids = scan_todo_ids(buf),
					})
					conceal.apply_buffer_conceal(buf)
				else
					code_render.render_file(buf)
				end
			end, 30)
		end,
	})
end

--- 退出插入模式时自动保存（仅 TODO 文件）
function M.setup_insert_leave()
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = "*.todo,*.todo.md",
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if not buffer.is_valid(buf) then
				return
			end

			if not vim.api.nvim_get_option_value("modified", { buf = buf }) then
				return
			end

			local path = buffer.get_path(buf)
			autosave.flush(buf, function(success, err)
				if success then
					events.on_state_changed({
						source = "todo_autosave",
						file = path,
						bufnr = buf,
						changed_ids = scan_todo_ids(buf),
					})
					conceal.apply_buffer_conceal(buf)
				elseif err then
					vim.notify("自动保存失败: " .. err, vim.log.levels.ERROR)
				end
			end)
		end,
	})
end

function M.cleanup(bufnr)
	if bufnr then
		stop_timer(debounce_timers[bufnr])
		debounce_timers[bufnr] = nil
	else
		for _, timer_obj in pairs(debounce_timers) do
			stop_timer(timer_obj)
		end
		debounce_timers = {}
	end
end

function M.setup()
	M.setup_initial_render()
	M.setup_text_change()
	M.setup_write_pre()
	M.setup_write_post()
	M.setup_insert_leave()

	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			M.cleanup(args.buf)
		end,
	})
end

return M
