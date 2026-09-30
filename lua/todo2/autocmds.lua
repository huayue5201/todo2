-- lua/todo2/autocmds.lua
-- 统一事件处理：TODO 文件 + 代码文件渲染

local M = {}

local events = require("todo2.core.events")
local id = require("todo2.utils.id")
local autosave = require("todo2.core.autosave")
local core = require("todo2.store.task.core")
local format = require("todo2.utils.format")
local sync = require("todo2.core.sync")
local conceal = require("todo2.render.conceal")
local buffer = require("todo2.utils.buffer")
local file = require("todo2.utils.file")
local code_render = require("todo2.render.code_render")
local code_tracker = require("todo2.core.code_tracker")
local code_block = require("todo2.code_block")

local async_util = require("todo2.utils.async")

local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })
local debounce_tasks = {}

--- 扫描 TODO 文件中的所有任务 ID
---@param bufnr number
---@return string[]
local function scan_todo_ids(bufnr)
	local ids = {}
	local lines = buffer.get_lines(bufnr)

	for _, line in ipairs(lines) do
		local id = id.extract_id_from_line(line)
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

--- 渲染单个 buffer（TODO 文件走同步+conceal，代码文件走 extmark 标记）。
--- 提取为公共函数：既被 BufRead 自动渲染使用，也供惰性入口手动调用。
function M.render_buffer(buf)
	if not buffer.is_valid(buf) then
		return
	end

	local path = buffer.get_path(buf)

	if file.is_todo_file(path) then
		-- ⭐ 同步存储（建立索引和父子关系，否则进度条/统计会显示“暂无任务”）
		pcall(sync.sync_todo_file, path)

		events.emit("initial_render", {
			file = path,
			bufnr = buf,
			changed_ids = scan_todo_ids(buf),
		})
		conceal.apply_buffer_conceal(buf)
	else
		code_render.render_file(buf)
	end
end

--- 文件打开时统一渲染
function M.setup_initial_render()
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			async_util.delay(50, function()
				M.render_buffer(buf)
			end)
		end,
	})
end

--- 文本变更时同步存储（仅 TODO 文件，仅同步内容不同步 checkbox）
function M.setup_text_change()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		pattern = file.todo_autocmd_pattern(),
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
				events.emit("todo_edit", {
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
		pattern = file.todo_autocmd_pattern(),
		callback = function(args)
			local buf = args.buf
			if not buffer.is_valid(buf) then
				return
			end

			local path = buffer.get_path(buf)
			if path == "" then
				return
			end

			-- 防抖：取消上一轮，300ms 后同步存储
			async_util.debounce(debounce_tasks, buf, 300, function()
				if buffer.is_valid(buf) then
					local result = sync.sync_todo_file(path)
					if #result.changed_ids > 0 then
						events.emit("todo_sync", {
							file = path,
							bufnr = buf,
							changed_ids = result.changed_ids,
						})
						conceal.apply_buffer_conceal(buf)
					end
				end
			end)
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

			async_util.delay(30, function()
				if not buffer.is_valid(buf) then
					return
				end

				if file.is_todo_file(path) then
					events.emit("todo_save", {
						file = path,
						bufnr = buf,
						changed_ids = scan_todo_ids(buf),
					})
					conceal.apply_buffer_conceal(buf)
				else
					code_render.render_file(buf)
				end
			end)
		end,
	})
end

--- 退出插入模式时自动保存（仅 TODO 文件）
function M.setup_insert_leave()
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = file.todo_autocmd_pattern(),
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
					events.emit("todo_autosave", {
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
		async_util.cancel(debounce_tasks, bufnr)
	else
		for _, key in ipairs(vim.tbl_keys(debounce_tasks)) do
			async_util.cancel(debounce_tasks, key)
		end
	end
end

function M.setup()
	M.setup_initial_render()
	M.setup_text_change()
	M.setup_write_pre()
	M.setup_write_post()
	M.setup_insert_leave()
	code_tracker.setup()

	-- LSP 附加到 buffer 后，预取 documentSymbol 符号表，
	-- 使同步的 get_block_at_line / get_all_blocks 能命中 LSP 缓存
	vim.api.nvim_create_autocmd("LspAttach", {
		group = augroup,
		callback = function(args)
			async_util.delay(100, function()
				if buffer.is_valid(args.buf) then
					code_block.prefetch_symbols(args.buf)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			M.cleanup(args.buf)
		end,
	})
end

return M
