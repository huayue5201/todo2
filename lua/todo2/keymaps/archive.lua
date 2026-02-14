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
local locator = require("todo2.store.locator")

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
-- ⭐ 完整的撤销归档功能
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

	-- =========================================================
	-- 3. 处理 TODO 文件：移出归档区，放回活跃区
	-- =========================================================
	local todo_path = vim.api.nvim_buf_get_name(bufnr)
	local todo_lines = read_all_lines(todo_path)

	-- 删除归档行
	if lnum <= #todo_lines then
		table.remove(todo_lines, lnum)
	end

	-- 查找活跃区位置
	local insert_pos = find_active_section_position(todo_lines)

	-- 生成新的任务行（活跃状态）
	local new_todo_line = format.format_task_line({
		indent = "",
		checkbox = "[ ]",
		id = id,
		tag = (snapshot.todo and snapshot.todo.tag) or "TODO",
		content = (snapshot.todo and snapshot.todo.content) or "",
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
	-- 4. ⭐ 恢复代码标记（只恢复标记格式，不添加内容）
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

			-- ⭐ 只生成标记格式：-- TODO:ref:004654
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

				vim.notify(
					string.format(
						"已恢复代码标记 %s 到 %s:%d",
						marker_line,
						vim.fn.fnamemodify(code_path, ":t"),
						insert_line
					),
					vim.log.levels.INFO
				)
			end
		end
	end

	-- =========================================================
	-- 5. 更新存储状态
	-- =========================================================
	store_link.unarchive_link(id)

	-- =========================================================
	-- 6. 清理解析器缓存
	-- =========================================================
	parser.invalidate_cache(todo_path)
	if snapshot.code and snapshot.code.path then
		parser.invalidate_cache(snapshot.code.path)
	end

	vim.notify(
		string.format("✅ 任务 %s 已撤销归档，恢复为活跃状态", id:sub(1, 6)),
		vim.log.levels.INFO
	)
end

---------------------------------------------------------------------
-- 交互式撤销归档
---------------------------------------------------------------------
function M.unarchive_tasks_interactive()
	local snapshots = store_link.get_all_archive_snapshots()

	if #snapshots == 0 then
		vim.notify("没有可撤销的归档任务", vim.log.levels.INFO)
		return
	end

	local choices = {}
	for _, s in ipairs(snapshots) do
		local task_desc = string.format(
			"[%s] %s - %s (代码: %s)",
			s.id:sub(1, 6),
			(s.todo and s.todo.content or "未知任务"):sub(1, 40),
			os.date("%Y-%m-%d %H:%M", s.archived_at or 0),
			s.code and vim.fn.fnamemodify(s.code.path, ":t") or "无代码标记"
		)
		table.insert(choices, {
			text = task_desc,
			id = s.id,
		})
	end

	vim.ui.select(choices, {
		prompt = "📋 选择要撤销归档的任务：",
		format_item = function(item)
			return item.text
		end,
	}, function(choice)
		if choice then
			local snapshot = store_link.get_archive_snapshot(choice.id)
			if snapshot and snapshot.todo and snapshot.todo.path then
				local bufnr = vim.fn.bufnr(snapshot.todo.path)
				if bufnr == -1 then
					bufnr = vim.fn.bufadd(snapshot.todo.path)
					vim.fn.bufload(bufnr)
				end
				vim.cmd("buffer " .. bufnr)
				-- 查找归档行
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				for i, line in ipairs(lines) do
					if line:match("{#" .. choice.id .. "}") then
						vim.fn.cursor(i, 1)
						break
					end
				end
				M.unarchive_task()
			end
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
				"[%s] %s (代码标记: %s)",
				s.id:sub(1, 6),
				(s.todo and s.todo.content or "未知任务"):sub(1, 50),
				s.code and string.format("%s:ref:%s", s.code.tag or "TODO", s.id) or "无"
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
