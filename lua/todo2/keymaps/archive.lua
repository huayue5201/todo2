-- lua/todo2/keymaps/archive.lua
--- @module todo2.keymaps.archive

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local archive = require("todo2.core.archive")
local parser = require("todo2.core.parser")
local ui = require("todo2.ui")
local store_link = require("todo2.store.link")
local format = require("todo2.utils.format")
local types = require("todo2.store.types") -- ⭐ 新增：用于状态转换

---------------------------------------------------------------------
-- 文件操作辅助函数
---------------------------------------------------------------------
local function read_all_lines(path)
	if vim.fn.filereadable(path) == 1 then
		return vim.fn.readfile(path)
	end
	return {}
end

local function write_all_lines(path, lines)
	vim.fn.writefile(lines, path)
end

---------------------------------------------------------------------
-- 获取文件类型的注释前缀
---------------------------------------------------------------------
local function get_comment_prefix(filepath)
	if filepath:match("%.lua$") then
		return "--"
	elseif
		filepath:match("%.js$")
		or filepath:match("%.ts$")
		or filepath:match("%.jsx$")
		or filepath:match("%.tsx$")
	then
		return "//"
	elseif filepath:match("%.py$") or filepath:match("%.rb$") then
		return "#"
	elseif
		filepath:match("%.java$")
		or filepath:match("%.cpp$")
		or filepath:match("%.c$")
		or filepath:match("%.h$")
	then
		return "//"
	elseif filepath:match("%.go$") then
		return "//"
	elseif filepath:match("%.rs$") then
		return "//"
	elseif filepath:match("%.php$") then
		return "//"
	elseif filepath:match("%.sh$") then
		return "#"
	else
		return "--" -- 默认
	end
end

---------------------------------------------------------------------
-- 查找 ## Active 位置
---------------------------------------------------------------------
local function find_active_section_position(lines)
	for i, line in ipairs(lines) do
		if line == "## Active" then
			return i + 1 -- Active标题的下一行
		end
	end
	-- 如果没有找到，在文件末尾添加
	table.insert(lines, "")
	table.insert(lines, "## Active")
	table.insert(lines, "")
	return #lines - 1
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
-- ⭐ 撤销归档（严格按存储状态恢复）
---------------------------------------------------------------------
function M.unarchive_task()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]

	-- 1. 提取任务ID
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
	-- 3. 先更新存储状态（存储是唯一真相）
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
	-- 4. 根据存储状态更新 TODO 文件
	-- =========================================================
	local todo_path = vim.api.nvim_buf_get_name(bufnr)
	local todo_lines = read_all_lines(todo_path)

	-- 删除归档行
	if lnum <= #todo_lines then
		table.remove(todo_lines, lnum)
	end

	-- 查找活跃区位置
	local insert_pos = find_active_section_position(todo_lines)

	-- ⭐ 严格按照存储状态生成 checkbox
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

	-- 写回 TODO 文件
	write_all_lines(todo_path, todo_lines)

	-- 刷新 TODO 缓冲区
	if ui and ui.refresh then
		ui.refresh(bufnr, true)
	end

	-- =========================================================
	-- 5. 恢复代码标记（如果快照中有）
	-- =========================================================
	if snapshot.code then
		local code_data = snapshot.code
		local code_path = code_data.path

		if vim.fn.filereadable(code_path) == 1 then
			local code_lines = read_all_lines(code_path)

			-- 确定插入位置
			local insert_line = code_data.line
			if insert_line > #code_lines then
				insert_line = #code_lines + 1
			end

			-- 获取注释前缀
			local comment_prefix = get_comment_prefix(code_path)

			-- 获取标签
			local tag = code_data.tag or "TODO"

			-- 生成标记行
			local marker_line = string.format("%s %s:ref:%s", comment_prefix, tag, id)

			-- 检查是否已存在
			local exists = false
			for _, l in ipairs(code_lines) do
				if l:find(":ref:" .. id) then
					exists = true
					break
				end
			end

			if not exists then
				table.insert(code_lines, insert_line, marker_line)
				write_all_lines(code_path, code_lines)

				-- 重新创建代码链接
				store_link.add_code(id, {
					path = code_path,
					line = insert_line,
					content = marker_line,
					tag = tag,
					context = code_data.context,
				})

				-- 刷新代码缓冲区
				local code_bufnr = vim.fn.bufnr(code_path)
				if code_bufnr ~= -1 then
					pcall(vim.api.nvim_buf_call, code_bufnr, function()
						vim.cmd("silent edit!")
					end)
				end
			end
		end
	end

	-- =========================================================
	-- 6. 清理解析器缓存
	-- =========================================================
	parser.invalidate_cache(todo_path)
	if snapshot.code and snapshot.code.path then
		parser.invalidate_cache(snapshot.code.path)
	end

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

---------------------------------------------------------------------
-- 清理过期归档任务
---------------------------------------------------------------------
function M.cleanup_expired_archives()
	if not archive or not archive.cleanup_expired_archives then
		vim.notify("归档模块未加载", vim.log.levels.ERROR)
		return
	end

	local total, msg = archive.cleanup_expired_archives()
	vim.notify(string.format("已清理 %d 个过期归档任务", total or 0), vim.log.levels.INFO)
end

return M
