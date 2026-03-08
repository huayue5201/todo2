-- 自动命令管理模块（精简版 - 适配无软删除 & 精简 verification/consistency/meta）

local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local index_mod = require("todo2.store.index")
local link_mod = require("todo2.store.link")
local format = require("todo2.utils.format")

---------------------------------------------------------------------
-- 自动命令组
---------------------------------------------------------------------
local augroup = vim.api.nvim_create_augroup("Todo2", { clear = true })

---------------------------------------------------------------------
-- 防抖管理器（安全）
---------------------------------------------------------------------
local DebounceManager = {}
local debounce_timers = {}
local periodic_timers = {}

local function safe_close_timer(timer)
	if not timer then
		return
	end
	pcall(function()
		if timer:is_closing() ~= true then
			timer:stop()
			timer:close()
		end
	end)
end

function DebounceManager.debounce(key, callback, delay)
	if debounce_timers[key] then
		debounce_timers[key] = nil
	end

	debounce_timers[key] = vim.defer_fn(function()
		if debounce_timers[key] then
			pcall(callback)
			debounce_timers[key] = nil
		end
	end, delay)
end

function DebounceManager.create_periodic(key, interval_ms, callback)
	if periodic_timers[key] then
		safe_close_timer(periodic_timers[key])
		periodic_timers[key] = nil
	end

	local timer = vim.loop.new_timer()
	timer:start(interval_ms, interval_ms, function()
		vim.schedule(function()
			pcall(callback)
		end)
	end)

	periodic_timers[key] = timer
	return timer
end

function DebounceManager.cleanup_all()
	for key, _ in pairs(debounce_timers) do
		debounce_timers[key] = nil
	end
	debounce_timers = {}

	for key, timer in pairs(periodic_timers) do
		safe_close_timer(timer)
		periodic_timers[key] = nil
	end
	periodic_timers = {}
end

---------------------------------------------------------------------
-- autocmd 注册
---------------------------------------------------------------------
local function register_autocmd(event, opts)
	vim.api.nvim_create_autocmd(event, {
		group = opts.group or augroup,
		pattern = opts.pattern or "*",
		callback = opts.callback,
		desc = opts.desc or "",
	})
end

---------------------------------------------------------------------
-- Buffer 工具
---------------------------------------------------------------------
local function is_valid_buffer(bufnr)
	return vim.api.nvim_buf_is_valid(bufnr)
end

local function get_buffer_filepath(bufnr)
	return vim.api.nvim_buf_get_name(bufnr)
end

local function is_code_file(filepath)
	return filepath ~= "" and not filepath:match("%.todo%.md$")
end

local function is_todo_file(filepath)
	return filepath:match("%.todo%.md$") or filepath:match("%.todo$")
end

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------
function M.setup()
	M.setup_text_change_handlers()
	M.setup_buffer_write_handlers()
	M.setup_periodic_maintenance()
	M.setup_autolocate_autocmd()
	M.setup_incremental_tracking()
	M.setup_ui_render_autocmds()
end

---------------------------------------------------------------------
-- TextChanged / TextChangedI
---------------------------------------------------------------------
function M.setup_text_change_handlers()
	register_autocmd({ "TextChanged", "TextChangedI" }, {
		pattern = "*",
		desc = "处理代码文件和TODO文件的文本变更",
		callback = function(args)
			local bufnr = args.buf
			if not is_valid_buffer(bufnr) then
				return
			end

			local filepath = get_buffer_filepath(bufnr)
			if filepath == "" then
				return
			end

			-- 代码文件：提取 ID 并触发事件
			if is_code_file(filepath) then
				DebounceManager.debounce("render:" .. bufnr, function()
					local ids = {}
					pcall(function()
						ids = format.extract_ids_from_current_line(bufnr) or {}
					end)

					events.on_state_changed({
						source = "code_buffer_edit",
						file = filepath,
						bufnr = bufnr,
						ids = ids,
					})
				end, 100)
			end

			-- TODO 文件：更新内容并触发事件
			if is_todo_file(filepath) then
				DebounceManager.debounce("todo_change:" .. bufnr, function()
					pcall(function()
						local cursor = vim.api.nvim_win_get_cursor(0)
						if not cursor then
							return
						end

						local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1]
						if not line then
							return
						end

						local parsed = format.parse_task_line(line)
						if parsed and parsed.id then
							local store = require("todo2.store")
							local link = store.link.get_todo(parsed.id, { verify_line = false })

							if link and link.content ~= parsed.content then
								link.content = parsed.content
								link.updated_at = os.time()
								store.link.update_todo(parsed.id, link)
							end
						end

						events.on_state_changed({
							source = "content_change",
							file = filepath,
							bufnr = bufnr,
							timestamp = os.time() * 1000,
						})
					end)
				end, 300)
			end
		end,
	})
end

---------------------------------------------------------------------
-- BufWritePost / InsertLeave
---------------------------------------------------------------------
function M.setup_buffer_write_handlers()
	-- TODO 文件自动保存
	register_autocmd("InsertLeave", {
		pattern = "*.todo.md",
		desc = "TODO 文件离开插入模式时自动保存",
		callback = function()
			local bufnr = vim.api.nvim_get_current_buf()
			if not is_valid_buffer(bufnr) then
				return
			end
			if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
				return
			end

			local bufname = get_buffer_filepath(bufnr)
			if autosave and autosave.flush then
				pcall(function()
					if autosave.flush(bufnr) then
						local todo_links = index_mod.find_todo_links_by_file(bufname) or {}
						local ids = {}
						for _, link in ipairs(todo_links) do
							if link.id then
								table.insert(ids, link.id)
							end
						end

						if #ids > 0 then
							events.on_state_changed({
								source = "autosave",
								file = bufname,
								bufnr = bufnr,
								ids = ids,
							})
						end
					end
				end)
			end
		end,
	})

	-- 保存代码文件 → 自动同步
	register_autocmd("BufWritePost", {
		pattern = "*",
		desc = "文件保存后进行链接同步和状态更新",
		callback = function(args)
			local bufnr = args.buf
			if not is_valid_buffer(bufnr) then
				return
			end

			local filepath = get_buffer_filepath(bufnr)
			if not is_code_file(filepath) then
				return
			end

			pcall(function()
				local autofix = require("todo2.store.autofix")
				if not autofix.should_process_file(filepath) then
					return
				end

				local report = autofix.sync_code_links(filepath)

				if report and report.success then
					vim.notify(
						string.format("已同步 %d 个代码标记", (report.updated or 0)),
						vim.log.levels.DEBUG
					)
				end

				events.on_state_changed({
					source = "code_file_save",
					file = filepath,
					bufnr = bufnr,
					ids = report and report.ids or {},
				})
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 定期维护（只保留归档清理）
---------------------------------------------------------------------
function M.setup_periodic_maintenance()
	-- 归档清理（24小时）
	DebounceManager.create_periodic("archive_cleanup", 24 * 60 * 60 * 1000, function()
		pcall(function()
			local cleanup = require("todo2.store.cleanup")
			local cleaned = cleanup.cleanup_expired_archives()
			if cleaned > 0 then
				vim.notify(
					string.format("🧹 归档清理: 已删除 %d 个30天前的归档链接", cleaned),
					vim.log.levels.INFO
				)
			end
		end)
	end)

	-- VimLeavePre 清理所有定时器
	register_autocmd("VimLeavePre", {
		desc = "Vim 退出时清理所有定时器",
		callback = function()
			DebounceManager.cleanup_all()
		end,
	})
end

---------------------------------------------------------------------
-- UI 渲染事件
---------------------------------------------------------------------
function M.setup_ui_render_autocmds()
	register_autocmd("BufWinEnter", {
		pattern = "*.todo.md",
		desc = "进入 TODO 窗口时触发渲染事件",
		callback = function(args)
			local bufnr = args.buf
			if not is_valid_buffer(bufnr) then
				return
			end

			local filepath = get_buffer_filepath(bufnr)
			if filepath == "" then
				return
			end

			events.on_state_changed({
				source = "ui_buf_enter",
				file = filepath,
				bufnr = bufnr,
			})
		end,
	})

	register_autocmd("TextChanged", {
		pattern = "*.todo.md",
		desc = "编辑 TODO 时触发渲染事件",
		callback = function(args)
			local bufnr = args.buf
			if not is_valid_buffer(bufnr) then
				return
			end

			local filepath = get_buffer_filepath(bufnr)
			if filepath == "" then
				return
			end

			events.on_state_changed({
				source = "ui_text_changed",
				file = filepath,
				bufnr = bufnr,
			})
		end,
	})

	register_autocmd("BufWritePost", {
		pattern = "*.todo.md",
		desc = "保存 TODO 时触发渲染事件",
		callback = function(args)
			local bufnr = args.buf
			if not is_valid_buffer(bufnr) then
				return
			end

			local filepath = get_buffer_filepath(bufnr)
			if filepath == "" then
				return
			end

			events.on_state_changed({
				source = "ui_buf_write",
				file = filepath,
				bufnr = bufnr,
			})
		end,
	})
end

---------------------------------------------------------------------
-- 自动重定位
---------------------------------------------------------------------
function M.setup_autolocate_autocmd()
	register_autocmd("BufEnter", {
		pattern = "*",
		desc = "自动重定位链接并更新上下文",
		callback = function(args)
			if not config.get("auto_relocate") then
				return
			end

			vim.schedule(function()
				if not is_valid_buffer(args.buf) then
					return
				end

				local filepath = get_buffer_filepath(args.buf)
				if not filepath or filepath == "" then
					return
				end

				pcall(function()
					local todo_links = index_mod.find_todo_links_by_file(filepath) or {}
					local code_links = index_mod.find_code_links_by_file(filepath) or {}
					local updated_ids = {}

					local verification = require("todo2.store.verification")

					for _, link in ipairs(todo_links) do
						local updated = link_mod.get_todo(link.id, { force_relocate = true })
						if updated and updated.context and verification.update_expired_context then
							if verification.update_expired_context(updated, 7) then
								table.insert(updated_ids, link.id)
							end
						end
					end

					for _, link in ipairs(code_links) do
						local updated = link_mod.get_code(link.id, { force_relocate = true })
						if updated and updated.context and verification.update_expired_context then
							if verification.update_expired_context(updated, 7) then
								table.insert(updated_ids, link.id)
							end
						end
					end

					if #todo_links > 0 or #code_links > 0 then
						local ids = {}
						for _, link in ipairs(todo_links) do
							table.insert(ids, link.id)
						end
						for _, link in ipairs(code_links) do
							table.insert(ids, link.id)
						end

						events.on_state_changed({
							source = "autolocate",
							file = filepath,
							bufnr = args.buf,
							ids = ids,
						})
					end

					if #updated_ids > 0 then
						vim.notify(string.format("已更新 %d 个过期上下文", #updated_ids), vim.log.levels.INFO)
					end
				end)
			end)
		end,
	})
end

---------------------------------------------------------------------
-- 增量追踪（on_bytes）
---------------------------------------------------------------------
function M.setup_incremental_tracking()
	local store = require("todo2.store.nvim_store")

	register_autocmd("BufReadPost", {
		pattern = "*",
		desc = "附加 on_bytes 监听器以实时更新行号偏移",
		callback = function(args)
			local bufnr = args.buf
			if vim.api.nvim_buf_get_option(bufnr, "buftype") ~= "" then
				return
			end

			vim.api.nvim_buf_attach(bufnr, false, {
				on_bytes = function(_, _, _, start_row, _, _, old_end_row, _, _, new_end_row, _, _)
					local diff = new_end_row - old_end_row
					if diff == 0 then
						return
					end

					pcall(function()
						local filepath = get_buffer_filepath(bufnr)
						local todo_links = index_mod.find_todo_links_by_file(filepath) or {}
						local code_links = index_mod.find_code_links_by_file(filepath) or {}

						local function update_list(list, prefix)
							for _, item in ipairs(list) do
								if item.line and (item.line - 1) > start_row then
									item.line = item.line + diff
									store.set_key(prefix .. item.id, item)
								end
							end
						end

						update_list(todo_links, "todo.links.todo.")
						update_list(code_links, "todo.links.code.")
					end)
				end,
			})
		end,
	})
end

return M
