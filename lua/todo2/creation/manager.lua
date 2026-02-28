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

local active_sessions = {} -- session_id -> session

--- 恢复原始窗口（通用函数）
local function restore_original_window(context)
	if context.original_win and vim.api.nvim_win_is_valid(context.original_win) then
		vim.api.nvim_set_current_win(context.original_win)
		if context.original_cursor then
			vim.api.nvim_win_set_cursor(context.original_win, context.original_cursor)
		end
	end
end

--- 校验行号有效性
--- @param bufnr number 缓冲区编号
--- @param line number 1-based行号
--- @return boolean 是否有效
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total_lines
end

--- 开始创建会话（从代码触发）
--- @param context table 包含:
---   - code_buf: 代码缓冲区
---   - code_line: 代码行号
---   - selected_tag: 已选择的标签（可选）
---   - original_win, original_cursor: 自动记录
function M.start_session(context)
	-- 1. 初始化上下文，强制从当前光标获取最新位置（核心修复）
	context = context or {}
	context.original_win = context.original_win or vim.api.nvim_get_current_win()
	context.original_cursor = context.original_cursor or vim.api.nvim_win_get_cursor(0)

	-- 强制覆盖：从当前光标获取准确的bufnr和行号
	context.code_buf = vim.api.nvim_get_current_buf()
	context.code_line = vim.api.nvim_win_get_cursor(0)[1]

	-- 2. 行号有效性校验（核心修复）
	if not validate_line_number(context.code_buf, context.code_line) then
		vim.notify(
			string.format(
				"行号无效！缓冲区%d总行数：%d，传入行号：%d",
				context.code_buf,
				vim.api.nvim_buf_line_count(context.code_buf),
				context.code_line or 0
			),
			vim.log.levels.ERROR
		)
		restore_original_window(context)
		return
	end

	-- ⭐ 3. 检查当前代码行是否已有标记（使用 id_utils）
	local line_content = vim.api.nvim_buf_get_lines(context.code_buf, context.code_line - 1, context.code_line, false)[1]
		or ""
	if id_utils.contains_code_mark(line_content) then -- 使用 id_utils 检查
		vim.notify("当前行已存在标记，请选择其他位置", vim.log.levels.WARN)
		restore_original_window(context)
		return
	end

	-- 4. 如果未选择标签，进入标签选择
	if not context.selected_tag then
		return M.select_tag(context)
	end

	-- 5. 选择 TODO 文件
	M.select_todo_file(context)
end

--- 选择标签
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

--- 选择 TODO 文件（支持新建）
function M.select_todo_file(context)
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	if not file_manager then
		vim.notify("无法获取文件管理器模块", vim.log.levels.ERROR)
		restore_original_window(context)
		return
	end

	local todo_files = file_manager.get_todo_files(project)
	local choices = {}

	-- 1. 添加现有 TODO 文件
	for _, f in ipairs(todo_files) do
		table.insert(choices, {
			project = project,
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
		})
	end

	-- 2. 添加“新建文件”选项（始终显示）
	table.insert(choices, {
		is_new = true,
		display = "➕ 新建文件...",
	})

	-- 动态提示语：无文件时直接引导新建
	local prompt = (#todo_files == 0) and "📁 当前项目暂无 TODO 文件，请新建一个："
		or "🗂️ 选择 TODO 文件："

	vim.ui.select(choices, {
		prompt = prompt,
		format_item = function(item)
			if item.is_new then
				return item.display
			else
				return string.format("%-20s • %s", item.project, item.display)
			end
		end,
	}, function(choice)
		if not choice then
			-- 用户取消选择
			restore_original_window(context)
			return
		end

		if choice.is_new then
			-- ⭐ 执行新建文件流程
			local new_path = file_manager.create_todo_file()
			if new_path then
				context.todo_path = new_path
				M.open_todo_window(context)
			else
				-- 用户取消输入或创建失败
				restore_original_window(context)
			end
		else
			-- 使用现有文件
			context.todo_path = choice.path
			M.open_todo_window(context)
		end
	end)
end

--- 打开 TODO 窗口并绑定多个确认键
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
				callback = function(target)
					M.execute_action(context, target, "parent")
				end,
				desc = "创建独立任务",
				once = true,
			},
			child = {
				key = "s",
				callback = function(target)
					M.execute_action(context, target, "child")
				end,
				desc = "创建子任务",
				once = true,
			},
			sibling = { -- ⭐ 同级任务
				key = "n", -- 使用 n 键创建同级任务
				callback = function(target)
					M.execute_action(context, target, "sibling")
				end,
				desc = "创建同级任务",
				once = true,
			},
			cancel = {
				key = "<ESC>",
				callback = function(target)
					restore_original_window(context)
					if target.winid and vim.api.nvim_win_is_valid(target.winid) then
						vim.api.nvim_win_close(target.winid, true)
					end
					vim.notify("已取消创建", vim.log.levels.INFO)
				end,
				desc = "取消",
				once = true,
			},
		},
	})

	if not bufnr or not winid then
		vim.notify("无法打开TODO文件", vim.log.levels.ERROR)
		restore_original_window(context)
		return
	end

	-- 记录会话
	local session_id = tostring(os.time()) .. tostring(math.random(9999))
	active_sessions[session_id] = {
		context = context,
		bufnr = bufnr,
		winid = winid,
	}
end

--- 直接使用指定路径打开 TODO 窗口（供外部调用）
function M.open_todo_window_with_path(path, context)
	context = context or {}
	context.todo_path = path
	return M.open_todo_window(context)
end

--- 执行具体的创建动作（策略分发）
function M.execute_action(context, target, action_type)
	local action_map = {
		parent = parent_action,
		child = child_action,
		sibling = sibling_action, -- ⭐ 添加 sibling 动作
	}
	local action_fn = action_map[action_type]
	if not action_fn then
		vim.notify("未知动作类型: " .. action_type, vim.log.levels.ERROR)
		return
	end

	-- pcall 返回: success, result1, result2, ...
	local success, result, msg = pcall(action_fn, context, target)
	if not success then
		-- 动作函数抛出异常，result 是错误信息
		vim.notify("执行动作时出错: " .. tostring(result), vim.log.levels.ERROR)
		if target.winid and vim.api.nvim_win_is_valid(target.winid) then
			vim.api.nvim_win_close(target.winid, true)
		end
		restore_original_window(context)
		return
	end

	-- 安全获取通知消息（确保为字符串）
	local notification_msg
	if type(msg) == "string" then
		notification_msg = msg
	elseif result then
		notification_msg = "创建成功"
	else
		notification_msg = "创建失败"
	end

	if result then
		vim.notify(notification_msg, vim.log.levels.INFO)
		-- ✅ 成功：保持窗口打开，不恢复光标
		return
	else
		vim.notify(notification_msg, vim.log.levels.ERROR)
		-- ❌ 失败时关闭窗口并恢复原始窗口/光标
		if target.winid and vim.api.nvim_win_is_valid(target.winid) then
			vim.api.nvim_win_close(target.winid, true)
		end
		restore_original_window(context)
	end
end

return M
