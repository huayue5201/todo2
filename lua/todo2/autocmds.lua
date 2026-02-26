-- lua/todo2/autocmds.lua
--- @module todo2.autocmds
--- @brief 自动命令管理模块（修复自动保存事件冲突）
--- ⭐ 增强：添加上下文指纹支持和区域刷新

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
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
-- 内部状态
---------------------------------------------------------------------
local render_timers = {}
M._archive_cleanup_timer = nil
M._consistency_timer = nil -- ⭐ 新增：一致性检查定时器

---------------------------------------------------------------------
-- 辅助函数：从行中提取ID
---------------------------------------------------------------------
-- NOTE:ref:08b2e7
local function extract_ids_from_line(line)
	if not line then
		return {}
	end

	local ids = {}
	for id in line:gmatch("{#(%w+)}") do
		table.insert(ids, id)
	end
	return ids
end

---------------------------------------------------------------------
-- 辅助函数：从当前行提取ID
---------------------------------------------------------------------
local function extract_ids_from_current_line(bufnr)
	-- ⭐ 1. 检查缓冲区有效性
	if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("缓冲区无效或已关闭", vim.log.levels.DEBUG)
		return {}
	end

	-- ⭐ 2. 检查缓冲区是否加载
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return {}
	end

	-- ⭐ 3. 安全获取光标位置
	local cursor
	local ok, result = pcall(vim.api.nvim_win_get_cursor, 0)
	if ok and result then
		cursor = result
	else
		-- 如果无法获取光标，尝试使用缓冲区第一行
		cursor = { 1, 0 }
	end

	-- ⭐ 4. 确保行号有效
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local line_num = math.max(1, math.min(cursor[1], line_count))

	-- ⭐ 5. 安全读取行内容
	local lines
	ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line_num - 1, line_num, false)
	if not ok or not lines or #lines == 0 then
		return {}
	end

	-- ⭐ 6. 提取ID
	return extract_ids_from_line(lines[1] or "")
end

---------------------------------------------------------------------
-- 初始化自动命令
---------------------------------------------------------------------
function M.setup()
	M.buf_set_extmark_autocmd()
	M.setup_autolocate_autocmd()
	M.setup_content_change_listener()
	M.setup_autosave_autocmd_fixed()
	M.setup_archive_cleanup()
	M.setup_consistency_check() -- ⭐ 新增：设置一致性检查
end

---------------------------------------------------------------------
-- 代码状态渲染自动命令（使用事件系统）
---------------------------------------------------------------------
function M.buf_set_extmark_autocmd()
	local group = vim.api.nvim_create_augroup("Todo2CodeStatus", { clear = true })

	-- 只监听文本变更，通过事件系统触发
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = "*",
		callback = function(args)
			local bufnr = args.buf
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			-- 获取文件名
			local file_path = vim.api.nvim_buf_get_name(bufnr)
			if file_path == "" or file_path:match("%.todo%.md$") then
				-- 不处理 todo.md 文件
				return
			end

			-- 防抖
			if render_timers[bufnr] then
				render_timers[bufnr]:stop()
				render_timers[bufnr] = nil
			end

			render_timers[bufnr] = vim.defer_fn(function()
				-- 通过事件系统触发更新
				local ev = {
					source = "code_buffer_edit",
					file = file_path,
					bufnr = bufnr,
				}

				-- 可选：提取当前行的ID
				local ids = extract_ids_from_current_line(bufnr)
				if ids then
					ev.ids = ids
				end

				events.on_state_changed(ev)
				render_timers[bufnr] = nil
			end, 100)
		end,
		desc = "文本变更时通过事件系统触发 TODO 状态更新",
	})

	-- 监听缓冲区写入，确保状态同步
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*",
		callback = function(args)
			local bufnr = args.buf
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			local file_path = vim.api.nvim_buf_get_name(bufnr)
			if file_path == "" or file_path:match("%.todo%.md$") then
				return
			end

			events.on_state_changed({
				source = "code_buffer_write",
				file = file_path,
				bufnr = bufnr,
			})
		end,
		desc = "代码缓冲区写入时通过事件系统触发 TODO 状态更新",
	})
end

---------------------------------------------------------------------
-- ⭐ 修复：内容变更监听器（支持区域刷新）
---------------------------------------------------------------------
function M.setup_content_change_listener()
	local group = vim.api.nvim_create_augroup("Todo2ContentChange", { clear = true })
	local content_timer = nil

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = { "*.todo.md", "*.todo" },
		callback = function(args)
			-- 防抖处理
			if content_timer then
				content_timer:stop()
				content_timer:close()
			end

			content_timer = vim.loop.new_timer()
			content_timer:start(300, 0, function()
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(args.buf) then
						return
					end

					local cursor = vim.api.nvim_win_get_cursor(0)
					local current_line = cursor[1]

					-- 获取当前行内容
					local line = vim.api.nvim_buf_get_lines(args.buf, current_line - 1, current_line, false)[1]

					-- 解析任务行
					local parsed = format.parse_task_line(line)

					if parsed and parsed.id then
						-- 更新存储
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
						file = vim.api.nvim_buf_get_name(args.buf),
						bufnr = args.buf,
						-- 移除 affected_lines
						timestamp = os.time() * 1000,
					})
				end)
			end)
		end,
	})
end

---------------------------------------------------------------------
-- ⭐ 修复：自动保存自动命令（添加上下文更新）
---------------------------------------------------------------------
function M.setup_autosave_autocmd_fixed()
	-- 离开插入模式时保存并触发事件
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = augroup,
		pattern = "*.todo.md",
		callback = function()
			local bufnr = vim.api.nvim_get_current_buf()
			local bufname = vim.api.nvim_buf_get_name(bufnr)

			-- 检查buffer是否有修改
			if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
				return -- 没有修改，不需要保存
			end

			if autosave and autosave.flush then
				-- 立即保存
				local success = autosave.flush(bufnr)

				-- ⭐ 使用事件系统触发更新
				if success then
					-- 同步到 store 并更新上下文
					local autofix = require("todo2.store.autofix")
					local verification = require("todo2.store.verification")

					local report = autofix.sync_todo_links(bufname)
					local context_report = nil
					if verification and verification.update_expired_contexts then
						context_report = verification.update_expired_contexts(bufname)
					end

					-- 获取当前文件中的所有链接ID
					if index_mod then
						local todo_links = index_mod.find_todo_links_by_file(bufname)
						local ids = {}

						for _, link in ipairs(todo_links) do
							if link.id then
								table.insert(ids, link.id)
							end
						end

						-- 如果找到链接，触发事件
						if #ids > 0 and events then
							events.on_state_changed({
								source = "autosave",
								file = bufname,
								bufnr = bufnr,
								ids = ids,
							})
						end
					end

					-- 显示通知
					if report and report.updated and report.updated > 0 then
						local msg = string.format("已同步 %d 个任务更新", report.updated)
						if context_report and context_report.updated and context_report.updated > 0 then
							msg = msg .. string.format("，更新 %d 个上下文", context_report.updated)
						end
						vim.notify(msg, vim.log.levels.INFO)
					end
				end
			end
		end,
		desc = "离开插入模式时保存TODO文件并通过事件系统触发刷新",
	})

	-- ⭐ 新增：监听代码文件保存，更新上下文
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local bufnr = args.buf
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			local filepath = vim.api.nvim_buf_get_name(bufnr)
			if filepath == "" or filepath:match("%.todo%.md$") then
				return
			end

			-- 检查文件是否包含标记
			local autofix = require("todo2.store.autofix")
			if not autofix.should_process_file(filepath) then
				return
			end

			-- 同步代码链接并更新上下文
			local verification = require("todo2.store.verification")
			local report = autofix.sync_code_links(filepath)
			local context_report = nil
			if verification and verification.update_expired_contexts then
				context_report = verification.update_expired_contexts(filepath)
			end

			if report and report.success then
				local msg = string.format("已同步 %d 个代码标记", (report.updated or 0))
				if context_report and context_report.updated and context_report.updated > 0 then
					msg = msg .. string.format("，更新 %d 个上下文", context_report.updated)
				end
				vim.notify(msg, vim.log.levels.DEBUG)
			end

			-- 触发事件
			if events then
				events.on_state_changed({
					source = "code_file_save",
					file = filepath,
					bufnr = bufnr,
					ids = report and report.ids or {},
				})
			end
		end,
		desc = "代码文件保存时同步标记并更新上下文",
	})

	-- ⭐ 新增：监听TODO文件变更，刷新相关代码缓冲区
	vim.api.nvim_create_autocmd("User", {
		pattern = "Todo2TaskStatusChanged",
		callback = function(args)
			local data = args.data
			if not data or not data.ids then
				return
			end

			-- 找到引用这些ID的代码缓冲区并触发事件
			if not link_mod or not events then
				return
			end

			local processed_files = {}
			for _, id in ipairs(data.ids) do
				local code_link = link_mod.get_code(id, { verify_line = true })
				if code_link and code_link.path and not processed_files[code_link.path] then
					processed_files[code_link.path] = true

					-- 触发代码缓冲区更新事件
					events.on_state_changed({
						source = "task_status_changed",
						file = code_link.path,
						ids = { id },
					})
				end
			end
		end,
		desc = "任务状态变更时触发相关代码缓冲区更新",
	})
end

---------------------------------------------------------------------
-- ⭐ 自动重新定位链接自动命令（添加上下文验证）
---------------------------------------------------------------------
function M.setup_autolocate_autocmd()
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		pattern = "*",
		callback = function(args)
			-- 获取配置
			local auto_relocate = config.get("auto_relocate")
			if not auto_relocate then
				return
			end

			vim.schedule(function()
				-- 检查 buffer 是否还存在
				if not vim.api.nvim_buf_is_valid(args.buf) then
					return
				end

				local filepath = vim.api.nvim_buf_get_name(args.buf)
				if not filepath or filepath == "" then
					return
				end

				-- 只在需要时重新定位链接（例如，首次打开文件时）
				local todo_links = index_mod.find_todo_links_by_file(filepath)
				local code_links = index_mod.find_code_links_by_file(filepath)

				-- ⭐ 重新定位并验证上下文
				local verification = require("todo2.store.verification")
				local updated_ids = {}

				for _, link in ipairs(todo_links) do
					local updated = link_mod.get_todo(link.id, { force_relocate = true })
					if updated and updated.context then
						if verification.update_expired_context then
							local result = verification.update_expired_context(updated, 7)
							if result then
								table.insert(updated_ids, link.id)
							end
						end
					end
				end
				for _, link in ipairs(code_links) do
					local updated = link_mod.get_code(link.id, { force_relocate = true })
					if updated and updated.context then
						if verification.update_expired_context then
							local result = verification.update_expired_context(updated, 7)
							if result then
								table.insert(updated_ids, link.id)
							end
						end
					end
				end

				-- 重新定位后触发事件刷新
				if (#todo_links > 0 or #code_links > 0) and events then
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

				-- ⭐ 显示上下文更新通知
				if #updated_ids > 0 then
					vim.notify(string.format("已更新 %d 个过期上下文", #updated_ids), vim.log.levels.INFO)
				end
			end)
		end,
		desc = "自动重新定位链接并更新上下文",
	})
end

---------------------------------------------------------------------
-- ⭐ 新增：归档链接自动清理
---------------------------------------------------------------------
function M.setup_archive_cleanup()
	local group = vim.api.nvim_create_augroup("Todo2ArchiveCleanup", { clear = true })

	-- 使用定时器每天执行一次
	local timer = vim.loop.new_timer()
	local interval = 24 * 60 * 60 * 1000 -- 24小时（毫秒）

	timer:start(interval, interval, function()
		vim.schedule(function()
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

	-- 保存timer引用
	M._archive_cleanup_timer = timer

	-- 在Vim退出时清理timer
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		pattern = "*",
		callback = function()
			if M._archive_cleanup_timer then
				M._archive_cleanup_timer:stop()
				M._archive_cleanup_timer:close()
				M._archive_cleanup_timer = nil
			end
		end,
		desc = "退出时清理归档清理定时器",
	})
end

---------------------------------------------------------------------
-- ⭐ 新增：数据一致性检查（每天执行一次）
---------------------------------------------------------------------
function M.setup_consistency_check()
	local group = vim.api.nvim_create_augroup("Todo2ConsistencyCheck", { clear = true })

	-- 使用定时器每天执行一次
	local timer = vim.loop.new_timer()
	local interval = 24 * 60 * 60 * 1000 -- 24小时（毫秒）

	timer:start(interval, interval, function()
		vim.schedule(function()
			local consistency = require("todo2.store.consistency")
			local cleanup = require("todo2.store.cleanup")
			local meta = require("todo2.store.meta")

			-- 执行完整一致性检查
			local report = consistency.check_all_pairs()

			if report.inconsistent_pairs > 0 or report.missing_todo > 0 or report.missing_code > 0 then
				-- 修复所有不一致的链接对
				for _, detail in ipairs(report.details) do
					if detail.needs_repair then
						consistency.repair_link_pair(detail.id, "latest")
					end
				end

				-- 清理悬挂数据
				cleanup.cleanup_dangling_links({ dry_run = false })

				-- 修复元数据
				meta.fix_counts()

				vim.notify(
					string.format(
						"✅ 数据一致性修复完成：修复了 %d 个问题",
						report.inconsistent_pairs + report.missing_todo + report.missing_code
					),
					vim.log.levels.INFO
				)
			end
		end)
	end)

	-- 保存timer引用
	M._consistency_timer = timer

	-- 在Vim退出时清理timer
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		pattern = "*",
		callback = function()
			if M._consistency_timer then
				M._consistency_timer:stop()
				M._consistency_timer:close()
				M._consistency_timer = nil
			end
		end,
		desc = "退出时清理一致性检查定时器",
	})
end

---------------------------------------------------------------------
-- 清理自动命令
---------------------------------------------------------------------
function M.clear()
	vim.api.nvim_clear_autocmds({ group = augroup })

	-- 清理渲染定时器
	for bufnr, timer in pairs(render_timers) do
		timer:stop()
	end
	render_timers = {}

	-- 清理归档清理定时器
	if M._archive_cleanup_timer then
		M._archive_cleanup_timer:stop()
		M._archive_cleanup_timer:close()
		M._archive_cleanup_timer = nil
	end

	-- ⭐ 清理一致性检查定时器
	if M._consistency_timer then
		M._consistency_timer:stop()
		M._consistency_timer:close()
		M._consistency_timer = nil
	end
end

---------------------------------------------------------------------
-- 重新应用自动命令
---------------------------------------------------------------------
function M.reapply()
	M.clear()
	M.setup()
end

return M
