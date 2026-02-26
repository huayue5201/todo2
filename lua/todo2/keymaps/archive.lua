-- lua/todo2/keymaps/archive.lua
--- @module todo2.keymaps.archive
--- 增强版：支持树完整性检查，准确识别任务类型

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
local renderer = require("todo2.task.renderer")
local autosave = require("todo2.core.autosave")
local events = require("todo2.core.events")
local conceal = require("todo2.ui.conceal")

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

-- 查找 ## Active 位置
local function find_active_section_position(lines)
	for i, line in ipairs(lines) do
		if line == "## Active" then
			local pos = i + 1
			while pos <= #lines and lines[pos]:match("^%s*$") do
				pos = pos + 1
			end
			return pos
		end
	end

	if #lines > 0 and lines[#lines] ~= "" then
		table.insert(lines, "")
	end
	table.insert(lines, "## Active")
	table.insert(lines, "")
	return #lines - 1
end

-- 判断是否为普通任务的归档行
local function is_normal_archived_task(line)
	return line:match("%[>%]") ~= nil and line:match("{#%w+}") == nil
end

-- 判断是否为双链任务的归档行
local function is_dual_archived_task(line)
	return line:match("%[>%].*{#%w+}") ~= nil
end

-- ⭐ 解析归档行的层级信息
local function parse_archive_line(line)
	local indent = line:match("^(%s*)") or ""
	local level = #indent / 2 -- 假设2空格为一缩进

	-- 提取内容
	local content = line:gsub("^%s*%- %[>%] ", ""):gsub("{#%w+} %w+: ", "")

	return {
		level = level,
		content = content,
		indent = indent,
	}
end

-- ⭐ 检查归档区的一行是否属于一个完整的树
local function is_complete_tree_in_archive(lines, start_lnum)
	local first_line = lines[start_lnum]
	if not first_line or not first_line:match("%[>%]") then
		return false, nil
	end

	local base_indent = #(first_line:match("^(%s*)") or "")
	local tree_lines = {}
	local end_lnum = start_lnum

	-- 收集这个树的所有行（直到遇到同级或更高级的缩进）
	for i = start_lnum, #lines do
		local line = lines[i]
		if not line or not line:match("%[>%]") then
			break
		end

		local indent = #(line:match("^(%s*)") or "")
		if indent < base_indent then
			break
		end

		table.insert(tree_lines, {
			lnum = i,
			line = line,
			indent = indent,
		})
		end_lnum = i
	end

	return true,
		{
			start_lnum = start_lnum,
			end_lnum = end_lnum,
			lines = tree_lines,
			base_indent = base_indent,
		}
end

---------------------------------------------------------------------
-- 普通任务撤销（树级别）
---------------------------------------------------------------------

-- ⭐ 批量撤销普通任务树
local function unarchive_normal_task_tree(bufnr, tree_info)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 1. 解析树中的所有任务
	local tasks = {}
	for _, line_info in ipairs(tree_info.lines) do
		local parsed = parse_archive_line(line_info.line)
		parsed.line_num = line_info.lnum
		table.insert(tasks, parsed)
	end

	-- 2. 找到 Active 区位置
	local active_pos = find_active_section_position(lines)

	-- 3. 生成恢复后的任务行（保持缩进和顺序）
	local new_lines = {}
	for _, task in ipairs(tasks) do
		local indent = string.rep("  ", task.level)
		local new_line = string.format("%s- [ ] %s", indent, task.content)
		table.insert(new_lines, new_line)
	end

	-- 4. 插入到 Active 区（保持原有顺序）
	for i, new_line in ipairs(new_lines) do
		table.insert(lines, active_pos + i - 1, new_line)
	end

	-- 5. 删除归档区的原行（从后往前）
	for i = #tasks, 1, -1 do
		table.remove(lines, tasks[i].line_num)
	end

	-- 6. 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(bufnr, "modified", true)

	if autosave then
		autosave.request_save(bufnr)
	end

	return true, active_pos
end

-- ⭐ 单个普通任务撤销（兼容单行情况）
local function unarchive_normal_task(bufnr, lnum, line)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 检查是否是树的一部分
	local is_tree, tree_info = is_complete_tree_in_archive(lines, lnum)

	if is_tree and tree_info and tree_info.end_lnum > tree_info.start_lnum then
		-- 这是一个完整的树，整个树一起撤销
		return unarchive_normal_task_tree(bufnr, tree_info)
	else
		-- 单个任务
		local indent, content = line:match("^(%s*)- %[>%] (.*)$")
		indent = indent or ""
		content = content or line:match("^%s*- %[>%] (.*)$") or ""

		-- 删除归档行
		table.remove(lines, lnum)

		-- 查找 Active 区
		local active_pos = find_active_section_position(lines)

		-- 插入新任务行
		local new_line = indent .. "- [ ] " .. content
		table.insert(lines, active_pos, new_line)

		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(bufnr, "modified", true)

		if autosave then
			autosave.request_save(bufnr)
		end

		return true, active_pos
	end
end

---------------------------------------------------------------------
-- 双链任务撤销（原有逻辑增强）
---------------------------------------------------------------------

-- ⭐ 撤销双链任务
local function unarchive_dual_task(id, bufnr, lnum, line)
	-- 1. 获取归档快照
	local snapshot = store_link.get_archive_snapshot(id)
	if not snapshot then
		vim.notify("找不到任务的归档快照", vim.log.levels.ERROR)
		return false
	end

	-- 验证快照完整性
	if not snapshot.todo or not snapshot.todo.status then
		vim.notify("归档快照不完整，无法恢复", vim.log.levels.ERROR)
		return false
	end

	-- =========================================================
	-- 2. 先更新存储状态
	-- =========================================================
	local unarchive_result = store_link.unarchive_link(id, {
		delete_snapshot = true,
		bufnr = bufnr,
	})

	if not unarchive_result then
		vim.notify("恢复存储状态失败", vim.log.levels.ERROR)
		return false
	end

	-- 获取恢复后的最新状态
	local restored_link = store_link.get_todo(id, { verify_line = true })
	if not restored_link then
		vim.notify("无法获取恢复后的任务状态", vim.log.levels.ERROR)
		return false
	end

	-- =========================================================
	-- 3. 更新 TODO 文件
	-- =========================================================
	local todo_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 删除归档行
	if lnum <= #todo_lines then
		table.remove(todo_lines, lnum)
	end

	-- 查找活跃区位置
	local insert_pos = find_active_section_position(todo_lines)

	-- 严格按照存储状态生成 checkbox（复用 previous_status）
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
	-- 4. 恢复代码标记（使用上下文指纹定位）
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

			-- 使用上下文指纹定位最佳插入位置
			local insert_line = code_data.line
			if snapshot.todo and snapshot.todo.context then
				local locator = require("todo2.store.locator")
				local context_result = locator.locate_by_context_fingerprint(code_path, snapshot.todo.context, 70)
				if context_result then
					insert_line = context_result.line
					-- 更新快照中的上下文
					snapshot.todo.context = context_result.context
					store_link.save_archive_snapshot(id, snapshot.code, snapshot.todo)
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

				-- 保存带有上下文的代码链接
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
	-- 5. 清理解析器缓存
	-- =========================================================
	local todo_path = vim.api.nvim_buf_get_name(bufnr)
	parser.invalidate_cache(todo_path)
	if snapshot.code and snapshot.code.path then
		parser.invalidate_cache(snapshot.code.path)
	end

	-- =========================================================
	-- 6. 触发事件
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
	-- 7. 刷新UI
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

	return true
end

---------------------------------------------------------------------
-- 主撤销函数
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

-- ⭐ 修改：撤销归档主函数
function M.unarchive_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	if not line then
		vim.notify("无法读取当前行", vim.log.levels.ERROR)
		return
	end

	-- 判断任务类型
	if is_normal_archived_task(line) and not is_dual_archived_task(line) then
		-- 普通任务
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local is_tree, tree_info = is_complete_tree_in_archive(lines, lnum)

		if is_tree and tree_info then
			-- 这是一个完整的树，整个树一起撤销
			local success, new_pos = unarchive_normal_task_tree(bufnr, tree_info)
			if success then
				vim.notify("✅ 完整任务树已撤销归档", vim.log.levels.INFO)

				-- 刷新UI
				vim.schedule(function()
					if ui and ui.refresh then
						ui.refresh(bufnr, true)
					end
					if conceal then
						conceal.apply_buffer_conceal(bufnr)
					end
					if new_pos then
						pcall(vim.api.nvim_win_set_cursor, 0, { new_pos, 0 })
					end
				end)
			end
		else
			-- 单个任务
			local success, new_pos = unarchive_normal_task(bufnr, lnum, line)
			if success then
				vim.notify("✅ 普通任务已撤销归档", vim.log.levels.INFO)

				vim.schedule(function()
					if ui and ui.refresh then
						ui.refresh(bufnr, true)
					end
					if conceal then
						conceal.apply_buffer_conceal(bufnr)
					end
					if new_pos then
						pcall(vim.api.nvim_win_set_cursor, 0, { new_pos, 0 })
					end
				end)
			end
		end
		return
	end

	-- 双链任务
	if is_dual_archived_task(line) then
		local id = line:match("{#(%w+)}")
		if not id then
			vim.notify("无法识别任务ID", vim.log.levels.WARN)
			return
		end

		-- 双链任务的树完整性由存储层保证，直接撤销
		unarchive_dual_task(id, bufnr, lnum, line)
		return
	end

	vim.notify("当前行不是归档任务", vim.log.levels.WARN)
end

-- ⭐ 批量撤销归档（处理混合类型）
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
		M.unarchive_task()
		return
	end

	-- 收集选中区域的所有归档行
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	local normal_count = 0
	local dual_ids = {}

	-- 从后往前处理，避免行号变化
	for i = #lines, 1, -1 do
		local line = lines[i]
		local current_lnum = start_line + i - 1

		if is_normal_archived_task(line) and not is_dual_archived_task(line) then
			-- 检查是否是完整树
			local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local is_tree, tree_info = is_complete_tree_in_archive(all_lines, current_lnum)

			if is_tree and tree_info then
				local success = unarchive_normal_task_tree(bufnr, tree_info)
				if success then
					normal_count = normal_count + 1
				end
			else
				local success = unarchive_normal_task(bufnr, current_lnum, line)
				if success then
					normal_count = normal_count + 1
				end
			end
		elseif is_dual_archived_task(line) then
			local id = line:match("{#(%w+)}")
			if id then
				table.insert(dual_ids, id)
			end
		end
	end

	-- 处理双链任务
	if #dual_ids > 0 then
		for _, id in ipairs(dual_ids) do
			-- 需要重新获取行号（可能已变化）
			-- 简化处理：提示用户单独处理
			vim.notify("批量撤销暂不支持双链任务，请单独处理", vim.log.levels.WARN)
		end
	end

	if normal_count > 0 then
		vim.notify(string.format("✅ 已撤销 %d 个普通任务树", normal_count), vim.log.levels.INFO)
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
