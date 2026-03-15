-- lua/todo2/creation/manager.lua

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local ui_window = require("todo2.ui.window")
local config = require("todo2.config")
local file_manager = require("todo2.ui.file_manager")
local parent_action = require("todo2.creation.actions.parent")
local child_action = require("todo2.creation.actions.child")
local sibling_action = require("todo2.creation.actions.sibling")
local id_utils = require("todo2.utils.id")
local format = require("todo2.utils.format")

local active_sessions = {} -- 这行是关键！

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function restore_original_window(context)
	if context.original_win and vim.api.nvim_win_is_valid(context.original_win) then
		vim.api.nvim_set_current_win(context.original_win)
		if context.original_cursor then
			vim.api.nvim_win_set_cursor(context.original_win, context.original_cursor)
		end
	end
end

local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total
end

---------------------------------------------------------------------
-- 构建 target（增强版）
---------------------------------------------------------------------
local function build_target(winid, bufnr, line)
	local line_content = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""

	local parsed = format.parse_task_line(line_content)
	local id = parsed and parsed.id or nil

	return {
		winid = winid,
		bufnr = bufnr,
		line = line,
		id = id,
		content = line_content,
	}
end

---------------------------------------------------------------------
-- 创建会话入口（从代码触发）
---------------------------------------------------------------------
function M.start_session(context)
	context = context or {}
	context.original_win = context.original_win or vim.api.nvim_get_current_win()
	context.original_cursor = context.original_cursor or vim.api.nvim_win_get_cursor(0)

	-- 强制从当前光标获取位置
	context.code_buf = vim.api.nvim_get_current_buf()
	context.code_line = vim.api.nvim_win_get_cursor(0)[1]

	if not validate_line_number(context.code_buf, context.code_line) then
		vim.notify("行号无效，无法创建任务", vim.log.levels.ERROR)
		restore_original_window(context)
		return
	end

	-- 检查当前行是否已有标记
	local line_content = vim.api.nvim_buf_get_lines(context.code_buf, context.code_line - 1, context.code_line, false)[1]
		or ""
	if id_utils.contains_code_mark(line_content) then
		vim.notify("当前行已存在标记，请选择其他位置", vim.log.levels.WARN)
		restore_original_window(context)
		return
	end

	-- 选择标签
	if not context.selected_tag then
		return M.select_tag(context)
	end

	-- 选择 TODO 文件
	M.select_todo_file(context)
end

---------------------------------------------------------------------
-- 标签选择
---------------------------------------------------------------------
function M.select_tag(context)
	local tags = config.get("tags") or {}
	local tag_choices = {}

	for tag, style in pairs(tags) do
		table.insert(tag_choices, {
			tag = tag,
			display = (style.icon or "") .. " " .. tag,
		})
	end

	if #tag_choices == 0 then
		tag_choices = { { tag = "TODO", display = "📝 TODO" } }
	end

	vim.ui.select(tag_choices, {
		prompt = "🏷️ 选择标签类型：",
		format_item = function(item)
			return string.format("%-12s • %s", item.tag, item.display)
		end,
	}, function(choice)
		if choice then
			context.selected_tag = choice.tag
			M.select_todo_file(context)
		else
			restore_original_window(context)
		end
	end)
end

---------------------------------------------------------------------
-- TODO 文件选择
---------------------------------------------------------------------
function M.select_todo_file(context)
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = file_manager.get_todo_files(project)
	local choices = {}

	for _, f in ipairs(todo_files) do
		table.insert(choices, {
			project = project,
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	table.insert(choices, {
		is_new = true,
		display = "➕ 新建文件...",
	})

	local prompt = (#todo_files == 0) and "📁 当前项目暂无 TODO 文件，请新建一个："
		or "🗂️ 选择 TODO 文件："

	vim.ui.select(choices, {
		prompt = prompt,
		format_item = function(item)
			return item.is_new and item.display or (item.project .. " • " .. item.display)
		end,
	}, function(choice)
		if not choice then
			restore_original_window(context)
			return
		end

		if choice.is_new then
			local new_path = file_manager.create_todo_file()
			if new_path then
				context.todo_path = new_path
				M.open_todo_window(context)
			else
				restore_original_window(context)
			end
		else
			context.todo_path = choice.path
			M.open_todo_window(context)
		end
	end)
end

---------------------------------------------------------------------
-- 打开 TODO 浮窗
---------------------------------------------------------------------
function M.open_todo_window(context)
	local path = context.todo_path
	local bufnr, winid = ui_window.open_with_actions(path, {
		type = "float",
		line = 1,
		enter_insert = false,
		show_hint = true,
		actions = {
			parent = {
				key = "p",
				desc = "创建独立任务",
				once = true,
				callback = function(target)
					M.execute_action(context, target, "parent")
				end,
			},
			child = {
				key = "s",
				desc = "创建子任务",
				once = true,
				callback = function(target)
					M.execute_action(context, target, "child")
				end,
			},
			sibling = {
				key = "n",
				desc = "创建同级任务",
				once = true,
				callback = function(target)
					M.execute_action(context, target, "sibling")
				end,
			},
			cancel = {
				key = "<ESC>",
				desc = "取消",
				once = true,
				callback = function(target)
					restore_original_window(context)
					if target.winid and vim.api.nvim_win_is_valid(target.winid) then
						vim.api.nvim_win_close(target.winid, true)
					end
					vim.notify("已取消创建", vim.log.levels.INFO)
				end,
			},
		},
	})

	if not bufnr or not winid then
		vim.notify("无法打开 TODO 文件", vim.log.levels.ERROR)
		restore_original_window(context)
		return
	end

	-- 记录会话
	local session_id = tostring(os.time()) .. tostring(math.random(9999))
	active_sessions[session_id] = { -- ⭐ 现在 active_sessions 存在了
		context = context,
		bufnr = bufnr,
		winid = winid,
	}
end

---------------------------------------------------------------------
-- 动作执行
---------------------------------------------------------------------
function M.execute_action(context, raw_target, action_type)
	local action_map = {
		parent = parent_action,
		child = child_action,
		sibling = sibling_action,
	}

	local action_fn = action_map[action_type]
	if not action_fn then
		vim.notify("未知动作类型：" .. action_type, vim.log.levels.ERROR)
		return
	end

	-- 构建增强版 target
	local target = build_target(raw_target.winid, raw_target.bufnr, raw_target.line)

	local ok, result, msg = pcall(action_fn, context, target)
	if not ok then
		vim.notify("执行动作时出错：" .. tostring(result), vim.log.levels.ERROR)
		if target.winid and vim.api.nvim_win_is_valid(target.winid) then
			vim.api.nvim_win_close(target.winid, true)
		end
		restore_original_window(context)
		return
	end

	local notification = type(msg) == "string" and msg or (result and "创建成功" or "创建失败")

	if result then
		vim.notify(notification, vim.log.levels.INFO)
	else
		vim.notify(notification, vim.log.levels.ERROR)
		if target.winid and vim.api.nvim_win_is_valid(target.winid) then
			vim.api.nvim_win_close(target.winid, true)
		end
		restore_original_window(context)
	end
end

return M
