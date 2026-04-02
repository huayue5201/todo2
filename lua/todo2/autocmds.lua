-- lua/todo2/autocmds.lua
-- 自动命令模块：负责监听文件变更并触发事件

---@module "todo2.autocmds"
---@brief m
---
--- 自动命令模块，监听 Neovim 的各种事件并触发相应的处理逻辑。
--- 包括文件打开、文本变更、文件保存等事件的处理。

local M = {}

local events = require("todo2.core.events")
local config = require("todo2.config")
local id_utils = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")
local format = require("todo2.utils.format")
local sync = require("todo2.core.sync")
local refactor = require("todo2.autofix.refactor")
local verification = require("todo2.autofix.verification")
local conceal = require("todo2.render.conceal")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")

---自动命令组
local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

---防抖定时器表
---@type table<number, uv_timer_t>
local debounce_timers = {}

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

---停止并关闭定时器
---@param timer uv_timer_t|nil
local function stop_timer(timer)
	if timer then
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end
end

---扫描文件中的所有任务 ID
---@param bufnr number 缓冲区号
---@return string[] 任务ID列表
local function scan_all_ids(bufnr)
	---@type table<string, boolean>
	local ids = {}
	local lines = buffer.get_lines(bufnr)

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

---扫描变更行附近的任务 ID
---@param bufnr number 缓冲区号
---@param changed_lines number[] 变更的行号列表
---@return string[] 任务ID列表
local function scan_changed_ids(bufnr, changed_lines)
	---@type table<string, boolean>
	local ids = {}
	local lines = buffer.get_lines(bufnr)

	-- 扩展扫描范围：前后各 5 行，确保捕获所有相关变更
	local min_line = math.max(1, math.min(unpack(changed_lines)) - 5)
	local max_line = math.min(#lines, math.max(unpack(changed_lines)) + 5)

	for line_num = min_line, max_line do
		local line = lines[line_num]
		if line and id_utils.contains_code_mark(line) then
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

---修复任务的复选框状态
---@param bufnr number 缓冲区号
---@param line_num number 行号
---@param expected_checkbox string 期望的复选框文本
---@return boolean 是否进行了修复
local function fix_checkbox(bufnr, line_num, expected_checkbox)
	local line = buffer.get_line(bufnr, line_num)
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

	vim.api.nvim_buf_set_text(bufnr, line_num - 1, start_col - 1, line_num - 1, end_col, { expected_checkbox })
	return true
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------

---设置初始渲染自动命令
function M.setup_initial_render()
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = augroup,
		desc = "文件打开时触发初始渲染事件",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			-- 延迟执行，确保文件完全加载
			vim.defer_fn(function()
				if not buffer.is_valid(buf) then
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
					-- TODO 文件：刷新所有任务
					events.on_state_changed({
						source = "initial_render",
						file = path,
						bufnr = buf,
						changed_ids = scan_all_ids(buf),
					})
				end

				conceal.apply_buffer_conceal(buf)
			end, 30)
		end,
	})
end

---设置文本变更自动命令
function M.setup_text_change()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		desc = "文本变更时处理：TODO文件同步存储，代码文件扫描ID",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			-- 代码文件处理
			if file.is_code_file(path) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				local line = cursor and cursor[1] or 1
				local changed = { line - 2, line - 1, line, line + 1, line + 2 }

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

			-- TODO 文件处理
			if file.is_todo_file(path) then
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
				---@type string[]
				local changed_ids = {}

				if parsed and parsed.id then
					local task = core.get_task(parsed.id)
					if task then
						-- 修复 checkbox
						local expected_checkbox = types.status_to_checkbox(task.core.status)
						if fix_checkbox(buf, line_num, expected_checkbox) then
							table.insert(changed_ids, parsed.id)
						end

						-- 实时同步内容
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

---设置文件保存自动命令
function M.setup_write()
	-- 代码文件保存前：保存快照
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = augroup,
		pattern = "*",
		desc = "代码文件保存前保存快照",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" or not file.is_code_file(path) then
				return
			end

			refactor.save_snapshot(buf)
		end,
	})

	-- TODO 文件保存前同步
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件保存前同步存储",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			-- 停止现有定时器
			stop_timer(debounce_timers[buf])

			-- 创建新定时器
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

	-- 代码文件保存后：检测移动并自动修复
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		desc = "代码文件保存后检测移动并自动修复",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" or not file.is_code_file(path) then
				return
			end

			-- 1. 检测移动并自动应用修复
			local moves = refactor.detect_block_move(buf)
			if #moves > 0 then
				refactor.apply_detected_moves(buf, true)
			end

			-- 2. 验证并修复文件中的任务
			verification.verify_file(path, function(results)
				if #results.updated + #results.deleted + #results.orphaned > 0 and config.get("notify_on_verify") then
					local msg = string.format(
						"任务验证: 更新 %d, 悬挂 %d, 删除 %d",
						#results.updated,
						#results.orphaned,
						#results.deleted
					)
					vim.notify(msg, vim.log.levels.INFO)
				end
			end)

			-- 3. 清除快照
			refactor.clear_snapshot(buf)

			-- 4. 触发事件刷新
			events.on_state_changed({
				source = "code_save",
				file = path,
				bufnr = buf,
				changed_ids = scan_all_ids(buf),
			})

			-- 5. 更新 conceal
			conceal.apply_buffer_conceal(buf)
		end,
	})

	-- TODO 文件保存后验证
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件保存后验证",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			-- 验证 TODO 文件中的任务
			verification.verify_file(path, function(results)
				if #results.updated + #results.deleted + #results.orphaned > 0 and config.get("notify_on_verify") then
					local msg = string.format(
						"任务验证: 更新 %d, 悬挂 %d, 删除 %d",
						#results.updated,
						#results.orphaned,
						#results.deleted
					)
					vim.notify(msg, vim.log.levels.INFO)
				end
			end)

			-- 触发事件刷新
			events.on_state_changed({
				source = "todo_save",
				file = path,
				bufnr = buf,
				changed_ids = scan_all_ids(buf),
			})

			conceal.apply_buffer_conceal(buf)
		end,
	})

	-- TODO 文件自动保存（InsertLeave）
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件退出插入模式时自动保存",
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
						changed_ids = scan_all_ids(buf),
					})
					conceal.apply_buffer_conceal(buf)
				elseif err then
					vim.notify("自动保存失败: " .. err, vim.log.levels.ERROR)
				end
			end)
		end,
	})
end

---设置 UI 渲染自动命令
function M.setup_ui()
	vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "BufWritePost" }, {
		group = augroup,
		pattern = { "*.todo", "*.todo.md" },
		desc = "TODO文件变更时触发渲染事件",
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			events.on_state_changed({
				source = "todo_ui",
				file = path,
				bufnr = buf,
				changed_ids = scan_all_ids(buf),
			})
		end,
	})
end

---清理资源
---@param bufnr number|nil 缓冲区号，为 nil 时清理所有
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

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------

---设置所有自动命令
function M.setup()
	M.setup_initial_render()
	M.setup_text_change()
	M.setup_write()
	M.setup_ui()

	-- 缓冲区删除时清理资源
	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			M.cleanup(args.buf)
		end,
	})
end

return M

