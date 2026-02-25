-- lua/todo2/keymaps/archive.lua
--- @module todo2.keymaps.archive
--- ⭐ 增强：撤销归档时使用上下文指纹定位

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local archive = require("todo2.core.archive")
local parser = require("todo2.core.parser")
local ui = require("todo2.ui")
local store_link = require("todo2.store.link")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local comment = require("todo2.utils.comment")
local renderer = require("todo2.link.renderer")
local autosave = require("todo2.core.autosave")
local events = require("todo2.core.events")
local conceal = require("todo2.ui.conceal")

-- 查找 ## Active 位置
---------------------------------------------------------------------
local function find_active_section_position(lines)
	for i, line in ipairs(lines) do
		-- TODO:ref:87df48
		if line == "## Active" then
			-- 返回 Active 区域后的位置
			local pos = i + 1
			-- 跳过可能的空行
			while pos <= #lines and lines[pos]:match("^%s*$") do
				pos = pos + 1
			end
			return pos
		end
	end

	-- 如果没有 ## Active，在文件末尾创建
	if #lines > 0 and lines[#lines] ~= "" then
		table.insert(lines, "")
	end
	table.insert(lines, "## Active")
	table.insert(lines, "")
	return #lines - 1 -- 返回 Active 后的位置
end

---------------------------------------------------------------------
-- 归档当前文件中所有已完成任务
---------------------------------------------------------------------
function M.archive_completed_tasks()
	if not archive then
		vim.notify("归档模块未加载", vim.log.levels.ERROR)
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local ok, msg, count = archive.archive_completed_tasks(bufnr, parser, { force_refresh = true })

	if ok then
		vim.notify(msg or string.format("成功归档 %d 个任务", count or 0), vim.log.levels.INFO)
	else
		vim.notify(msg or "归档失败", vim.log.levels.ERROR)
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：撤销普通任务的归档（纯文本操作）
---------------------------------------------------------------------
local function unarchive_normal_task(bufnr, lnum, line)
	-- 1. 提取任务内容和缩进
	local indent, content = line:match("^(%s*)- %[>%] (.*)$")
	if not indent then
		indent = ""
		content = line:match("^%s*- %[>%] (.*)$") or ""
	end

	-- 2. 读取当前文件所有行
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 3. 从归档区删除旧行
	table.remove(lines, lnum)

	-- 4. 查找或创建 Active 区
	local active_pos = find_active_section_position(lines)

	-- 5. 生成新任务行 ([ ] 代替 [>])
	local new_line = indent .. "- [ ] " .. content

	-- 6. 插入到 Active 区
	table.insert(lines, active_pos, new_line)

	-- 7. 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(bufnr, "modified", true)

	-- 8. 请求自动保存
	if autosave then
		autosave.request_save(bufnr)
	end

	return true, active_pos
end

---------------------------------------------------------------------
-- ⭐ 修改：撤销归档（支持普通任务和双链任务）
---------------------------------------------------------------------
function M.unarchive_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	if not line then
		vim.notify("无法读取当前行", vim.log.levels.ERROR)
		return
	end

	-- ⭐ 第一步：判断是否为普通任务的归档行
	if is_normal_archived_task(line) then
		-- 普通任务：纯文本撤销
		local success, new_pos = unarchive_normal_task(bufnr, lnum, line)

		if success then
			vim.notify("✅ 普通任务已撤销归档", vim.log.levels.INFO)

			-- 刷新UI
			vim.schedule(function()
				if ui and ui.refresh then
					ui.refresh(bufnr, true)
				end
				if conceal then
					conceal.apply_buffer_conceal(bufnr)
				end
				-- 移动光标到恢复的任务行
				pcall(vim.api.nvim_win_set_cursor, 0, { new_pos, 0 })
			end)
		else
			vim.notify("❌ 撤销归档失败", vim.log.levels.ERROR)
		end
		return
	end

	-- ⭐ 第二步：原有逻辑（处理双链任务）- 以下代码一字不改
	local id = line:match("{#(%w+)}")
	if not id then
		vim.notify("当前行不是有效任务", vim.log.levels.WARN)
		return
	end

	-- 2. 获取归档快照
	local snapshot = store_link.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到任务的归档快照", vim.log.levels.ERROR)
		return
	end

	-- 验证快照完整性
	if not snapshot.todo or not snapshot.todo.status then
		vim.notify("归档快照不完整，无法恢复", vim.log.levels.ERROR)
		return
	end

	-- =========================================================
	-- 3. 先更新存储状态
	-- =========================================================
	local unarchive_result = store_link.unarchive_link(id, {
		delete_snapshot = true,
		bufnr = bufnr,
	})

	if not unarchive_result then
		vim.notify("恢复存储状态失败", vim.log.levels.ERROR)
		return
	end

	-- 获取恢复后的最新状态
	local restored_link = store_link.get_todo(id, { verify_line = true })
	if not restored_link then
		vim.notify("无法获取恢复后的任务状态", vim.log.levels.ERROR)
		return
	end

	-- =========================================================
	-- 4. 更新 TODO 文件
	-- =========================================================
	local todo_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 删除归档行
	if lnum <= #todo_lines then
		table.remove(todo_lines, lnum)
	end

	-- 查找活跃区位置
	local insert_pos = find_active_section_position(todo_lines)

	-- 严格按照存储状态生成 checkbox
	local checkbox = types.status_to_checkbox(restored_link.status)

	-- 生成新的任务行
	local new_todo_line = format.format_task_line({
		indent = "",
		checkbox = checkbox,
		id = id,
		tag = restored_link.tag or "TODO",
		content = restored_link.content or "",
	})

	-- 插入到活跃区
	table.insert(todo_lines, insert_pos, new_todo_line)

	-- 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, todo_lines)
	vim.api.nvim_buf_set_option(bufnr, "modified", true)

	if autosave then
		autosave.request_save(bufnr)
	end

	-- =========================================================
	-- 5. ⭐ 恢复代码标记（增强：使用上下文指纹定位）
	-- =========================================================
	local code_updated = false
	if snapshot.code then
		local code_data = snapshot.code
		local code_path = code_data.path
		local code_bufnr = vim.fn.bufnr(code_path)

		if code_bufnr == -1 then
			code_bufnr = vim.fn.bufadd(code_path)
			vim.fn.bufload(code_bufnr)
		end

		if code_bufnr ~= -1 and vim.api.nvim_buf_is_valid(code_bufnr) then
			local code_lines = vim.api.nvim_buf_get_lines(code_bufnr, 0, -1, false)

			local tag = code_data.tag or "TODO"
			local marker_line = comment.generate_marker(id, tag, code_bufnr)

			-- ⭐ 使用上下文指纹定位最佳插入位置
			local insert_line = code_data.line
			if snapshot.todo and snapshot.todo.context then
				local locator = require("store.locator")
				local context_result = locator.locate_by_context_fingerprint(
					code_path,
					snapshot.todo.context,
					70 -- 相似度阈值
				)
				if context_result then
					insert_line = context_result.line
					-- 更新快照中的上下文
					snapshot.todo.context = context_result.context
					store_link.save_archive_snapshot(id, snapshot.code, snapshot.todo)

					vim.notify(
						string.format(
							"通过上下文指纹定位到行 %d (相似度: %d%%)",
							insert_line,
							context_result.similarity
						),
						vim.log.levels.INFO
					)
				end
			end

			-- 检查是否已存在标记
			local exists = false
			for _, l in ipairs(code_lines) do
				if l:find(":ref:" .. id) then
					exists = true
					break
				end
			end

			if not exists then
				-- 插入标记行
				local new_lines = {}
				for i = 1, #code_lines do
					if i == insert_line then
						table.insert(new_lines, marker_line)
					end
					table.insert(new_lines, code_lines[i])
				end
				if insert_line > #code_lines then
					table.insert(new_lines, marker_line)
				end

				vim.api.nvim_buf_set_lines(code_bufnr, 0, -1, false, new_lines)
				vim.api.nvim_buf_set_option(code_bufnr, "modified", true)

				-- ⭐ 保存带有上下文的代码链接
				store_link.add_code(id, {
					path = code_path,
					line = insert_line,
					content = marker_line,
					tag = tag,
					context = snapshot.todo and snapshot.todo.context or code_data.context,
					context_updated_at = os.time(),
				})

				if autosave then
					autosave.request_save(code_bufnr)
				end

				code_updated = true
			end
		end
	end

	-- =========================================================
	-- 6. 清理解析器缓存
	-- =========================================================
	local todo_path = vim.api.nvim_buf_get_name(bufnr)
	parser.invalidate_cache(todo_path)
	if snapshot.code and snapshot.code.path then
		parser.invalidate_cache(snapshot.code.path)
	end

	-- =========================================================
	-- 7. 触发完整UI更新事件
	-- =========================================================
	if events then
		events.on_state_changed({
			source = "unarchive_complete",
			bufnr = bufnr,
			file = todo_path,
			ids = { id },
		})

		if code_updated and snapshot.code and snapshot.code.path then
			local code_bufnr = vim.fn.bufnr(snapshot.code.path)
			if code_bufnr ~= -1 then
				events.on_state_changed({
					source = "unarchive_complete",
					bufnr = code_bufnr,
					file = snapshot.code.path,
					ids = { id },
				})
			end
		end
	end

	-- =========================================================
	-- 8. 手动刷新UI组件
	-- =========================================================
	vim.schedule(function()
		if ui and ui.refresh then
			ui.refresh(bufnr, true)
		end

		if conceal then
			conceal.apply_buffer_conceal(bufnr)
		end

		if code_updated and snapshot.code and snapshot.code.path then
			local code_bufnr = vim.fn.bufnr(snapshot.code.path)
			if code_bufnr ~= -1 then
				if renderer and renderer.render_code_status then
					renderer.render_code_status(code_bufnr)
				end
				if conceal then
					conceal.apply_buffer_conceal(code_bufnr)
				end
			end
		end
	end)

	-- 显示恢复信息
	-- TODO:ref:f91fc2
	local status_display = {
		[types.STATUS.COMPLETED] = "✓ 已完成",
		[types.STATUS.URGENT] = "❗ 紧急",
		[types.STATUS.WAITING] = "❓ 等待",
		[types.STATUS.NORMAL] = "◻ 正常",
	}

	vim.notify(
		string.format(
			"✅ 任务 %s 已撤销归档，恢复为 %s",
			id:sub(1, 6),
			status_display[restored_link.status] or restored_link.status
		),
		vim.log.levels.INFO
	)
end

---------------------------------------------------------------------
-- ⭐ 新增：批量撤销归档（处理混合类型）
---------------------------------------------------------------------
-- NOTE:ref:5e9b59
function M.batch_unarchive_tasks()
	local bufnr = vim.api.nvim_get_current_buf()
	local mode = vim.fn.mode()

	-- 获取选中的行范围
	local start_line, end_line
	if mode == "v" or mode == "V" then
		start_line = vim.fn.line("v")
		end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
	else
		-- 如果没有选中，只处理当前行
		M.unarchive_task()
		return
	end

	-- 收集选中区域的所有归档行
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	local normal_count = 0

	-- 从后往前处理，避免行号变化
	for i = #lines, 1, -1 do
		local line = lines[i]
		local current_lnum = start_line + i - 1

		if is_normal_archived_task(line) then
			-- 处理普通任务
			local success = unarchive_normal_task(bufnr, current_lnum, line)
			if success then
				normal_count = normal_count + 1
			end
		elseif line:match("{#") then
			-- 提示双链任务需要单独处理
			vim.notify("批量撤销暂不支持双链任务，请单独处理", vim.log.levels.WARN)
		end
	end

	if normal_count > 0 then
		vim.notify(string.format("✅ 已撤销 %d 个普通任务", normal_count), vim.log.levels.INFO)
	end

	-- 刷新UI
	vim.schedule(function()
		if ui and ui.refresh then
			ui.refresh(bufnr, true)
		end
		if conceal then
			conceal.apply_buffer_conceal(bufnr)
		end
	end)
end

---------------------------------------------------------------------
-- 查看归档历史
---------------------------------------------------------------------
function M.show_archive_history()
	local snapshots = store_link.get_all_archive_snapshots()

	if #snapshots == 0 then
		vim.notify("没有归档历史记录", vim.log.levels.INFO)
		return
	end

	local qf_list = {}
	for _, s in ipairs(snapshots) do
		table.insert(qf_list, {
			filename = s.todo and s.todo.path or "未知文件",
			lnum = s.todo and s.todo.line_num or 0,
			text = string.format(
				"[%s] %s (状态: %s, 代码标记: %s)",
				s.id:sub(1, 6),
				(s.todo and s.todo.content or "未知任务"):sub(1, 40),
				s.todo and s.todo.status or "unknown",
				s.code and "有" or "无"
			),
		})
	end

	vim.fn.setqflist(qf_list)
	vim.cmd("copen")
	vim.notify(string.format("找到 %d 条归档记录", #snapshots), vim.log.levels.INFO)
end

return M
