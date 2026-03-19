-- lua/todo2/autocmds.lua
-- 自动命令模块：负责监听文件变更并触发事件
-- 恢复：TODO 文件实时同步内容到存储

local M = {}

local events = require("todo2.core.events")
local config = require("todo2.config")
local id_utils = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")
local format = require("todo2.utils.format")
local index = require("todo2.store.index")
local sync = require("todo2.core.sync")
local refactor = require("todo2.core.refactor")
local conceal = require("todo2.render.conceal")
local file = require("todo2.utils.file")

local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

local debounce_timers = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

local function scan_all_ids(buf)
	local ids = {}
	local lines = file.get_buf_lines(buf)
	for _, line in ipairs(lines) do
		if id_utils.contains_code_mark(line) then
			local id = id_utils.extract_id_from_code_mark(line)
			if id then
				ids[id] = true
			end
		end
	end
	local result = {}
	for id in pairs(ids) do
		table.insert(result, id)
	end
	return result
end

local function scan_changed_ids(buf, changed_lines)
	local ids = {}
	local lines = file.get_buf_lines(buf)
	for _, l in ipairs(changed_lines) do
		if l >= 1 and l <= #lines then
			local line = lines[l]
			if line and id_utils.contains_code_mark(line) then
				local id = id_utils.extract_id_from_code_mark(line)
				if id then
					ids[id] = true
				end
			end
		end
	end
	local result = {}
	for id in pairs(ids) do
		table.insert(result, id)
	end
	return result
end

local function fix_checkbox(buf, line_num, expected_checkbox)
	local line = file.get_buf_line(buf, line_num)
	if not line or line == "" then
		return false
	end

	local start_col, end_col = format.get_checkbox_position(line)
	if not start_col or not end_col then
		return false
	end

	local current = line:sub(start_col, end_col)
	if current == expected_checkbox then
		return false
	end

	vim.api.nvim_buf_set_text(buf, line_num - 1, start_col - 1, line_num - 1, end_col, { expected_checkbox })
	return true
end

---------------------------------------------------------------------
-- 初始渲染
---------------------------------------------------------------------

function M.setup_initial_render()
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = augroup,
		desc = "文件打开时触发初始渲染事件",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end
			local path = file.buf_path(buf)
			if path == "" then
				return
			end

			vim.defer_fn(function()
				if not file.is_valid_buf(buf) then
					return
				end

				if file.is_code_file(path) then
					local ids = scan_all_ids(buf)
					if #ids > 0 then
						events.on_state_changed({
							source = "initial_render",
							file = path,
							bufnr = buf,
							changed_ids = ids,
						})
					end
				elseif file.is_todo_file(path) then
					events.on_state_changed({
						source = "initial_render",
						file = path,
						bufnr = buf,
					})
				end

				conceal.apply_buffer_conceal(buf)
			end, 30)
		end,
	})
end

---------------------------------------------------------------------
-- 文本变更处理（⭐ 已恢复实时同步内容）
---------------------------------------------------------------------

function M.setup_text_change()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		desc = "文本变更时处理：TODO文件同步存储，代码文件扫描ID",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end
			local path = file.buf_path(buf)
			if path == "" then
				return
			end

			-- 代码文件
			if file.is_code_file(path) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				local l = cursor and cursor[1] or 1
				local changed = { l - 2, l - 1, l, l + 1, l + 2 }

				local ids = scan_changed_ids(buf, changed)
				if #ids > 0 then
					events.on_state_changed({
						source = "code_edit",
						file = path,
						bufnr = buf,
						changed_ids = ids,
					})
				end

				conceal.apply_smart_conceal(buf, changed)
				return
			end

			-- TODO 文件
			if file.is_todo_file(path) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				if not cursor then
					return
				end

				local line_num = cursor[1]
				local line = file.get_buf_line(buf, line_num)
				if not line or line == "" then
					return
				end

				local parsed = format.parse_task_line(line)
				local changed_ids = {}

				if parsed and parsed.id then
					local task = core.get_task(parsed.id)
					if task then
						-- 修复 checkbox
						local expected_checkbox = types.status_to_checkbox(task.core.status)
						if fix_checkbox(buf, line_num, expected_checkbox) then
							table.insert(changed_ids, parsed.id)
						end

						-- ⭐ 恢复实时同步内容
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
			end
		end,
	})
end

---------------------------------------------------------------------
-- 文件保存处理
---------------------------------------------------------------------

function M.setup_write()
	-- TODO 文件自动保存
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件退出插入模式时自动保存",
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if not file.is_valid_buf(buf) then
				return
			end
			if not vim.api.nvim_get_option_value("modified", { buf = buf }) then
				return
			end

			local path = file.buf_path(buf)

			-- ✅ 使用回调，确保事件在保存完成后触发
			autosave.flush(buf, function(success, err, data)
				if success then
					events.on_state_changed({
						source = "todo_autosave",
						file = path,
						bufnr = buf,
					})
					conceal.apply_buffer_conceal(buf)
				elseif err then
					vim.notify("自动保存失败: " .. err, vim.log.levels.ERROR)
				end
			end)
		end,
	})

	-- TODO 文件保存前同步
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件保存前同步存储",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end
			local path = file.buf_path(buf)
			if path == "" then
				return
			end

			if debounce_timers[buf] then
				debounce_timers[buf]:stop()
				debounce_timers[buf]:close()
			end

			debounce_timers[buf] = vim.loop.new_timer()
			debounce_timers[buf]:start(
				300,
				0,
				vim.schedule_wrap(function()
					if vim.api.nvim_buf_is_valid(buf) then
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

	-- TODO 文件保存后触发渲染
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件保存后触发渲染更新",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end

			local path = file.buf_path(buf)
			events.on_state_changed({
				source = "todo_save",
				file = path,
				bufnr = buf,
			})
			conceal.apply_buffer_conceal(buf)
		end,
	})

	-- 代码文件保存后检测移动
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		desc = "代码文件保存后检测代码块移动",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end
			local path = file.buf_path(buf)
			if not file.is_code_file(path) then
				return
			end

			local moves = refactor.detect_block_move(buf)
			if #moves > 0 then
				vim.b[buf].detected_moves = moves

				local stats = refactor.get_move_stats(buf)
				vim.notify(
					string.format(
						"检测到 %d 个代码块移动（含 %d 个任务块），执行 :TodoApplyMove 确认",
						stats.total_blocks,
						stats.blocks_with_tasks
					),
					vim.log.levels.INFO
				)
			end

			refactor.clear_snapshot(buf)

			local ids = scan_all_ids(buf)
			if #ids > 0 then
				events.on_state_changed({
					source = "code_save",
					file = path,
					bufnr = buf,
					changed_ids = ids,
				})
			end

			conceal.apply_buffer_conceal(buf)
		end,
	})
end

---------------------------------------------------------------------
-- UI 渲染触发
---------------------------------------------------------------------

function M.setup_ui()
	vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "BufWritePost" }, {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件变更时触发渲染事件",
		callback = function(args)
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end
			local path = file.buf_path(buf)
			if path == "" then
				return
			end

			events.on_state_changed({
				source = "todo_ui",
				file = path,
				bufnr = buf,
			})
		end,
	})
end

---------------------------------------------------------------------
-- 自动重定位
---------------------------------------------------------------------

function M.setup_autolocate()
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		desc = "进入缓冲区时自动重定位任务",
		callback = function(args)
			if not config.get("auto_relocate") then
				return
			end
			local buf = args.buf
			if not file.is_valid_buf(buf) then
				return
			end

			local path = file.buf_path(buf)
			if path == "" then
				return
			end

			vim.schedule(function()
				local todo_links = index.find_todo_links_by_file(path) or {}
				local code_links = index.find_code_links_by_file(path) or {}

				local ids = {}
				for _, l in ipairs(todo_links) do
					table.insert(ids, l.id)
				end
				for _, l in ipairs(code_links) do
					table.insert(ids, l.id)
				end

				if #ids > 0 then
					events.on_state_changed({
						source = "autolocate",
						file = path,
						bufnr = buf,
						changed_ids = ids,
					})
				end

				conceal.apply_buffer_conceal(buf)
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 手动命令
---------------------------------------------------------------------

function M.setup_commands()
	vim.api.nvim_create_user_command("TodoSync", function()
		local buf = vim.api.nvim_get_current_buf()
		local path = file.buf_path(buf)
		if not file.is_todo_file(path) then
			vim.notify("不是TODO文件", vim.log.levels.ERROR)
			return
		end

		local result = sync.sync_todo_file(path)
		vim.notify(string.format("同步完成: %d 个任务变更", #result.changed_ids))

		events.on_state_changed({
			source = "manual_sync",
			file = path,
			bufnr = buf,
			changed_ids = result.changed_ids,
		})

		conceal.apply_buffer_conceal(buf)
	end, {})
end

---------------------------------------------------------------------
-- 清理
---------------------------------------------------------------------

function M.cleanup(buf)
	if buf and debounce_timers[buf] then
		debounce_timers[buf]:stop()
		debounce_timers[buf]:close()
		debounce_timers[buf] = nil
	end
end

---------------------------------------------------------------------
-- 入口
---------------------------------------------------------------------

function M.setup()
	M.setup_initial_render()
	M.setup_text_change()
	M.setup_write()
	M.setup_ui()
	M.setup_autolocate()
	M.setup_commands()

	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			M.cleanup(args.buf)
		end,
	})
end

return M
