--- File: /Users/lijia/todo2/lua/todo2/keymaps/handlers.lua ---
-- lua/todo2/keymaps/handlers.lua
--- @module todo2.keymaps.handlers
--- @brief 统一的按键处理器实现（适配新版存储API）

local M = {}

---------------------------------------------------------------------
-- 模块导入
---------------------------------------------------------------------
local module = require("todo2.module")
local helpers = require("todo2.utils.helpers")

---------------------------------------------------------------------
-- 辅助函数：适配存储API
---------------------------------------------------------------------
local function get_store_module()
	-- 注意：这里需要获取正确的模块路径
	-- 根据 store/link.lua 文件，应该获取 "store.link" 而不是 "store"
	local store_link = module.get("store.link")
	if not store_link then
		error("store.link模块未加载")
	end
	return store_link
end

---------------------------------------------------------------------
-- 核心：状态相关处理器
---------------------------------------------------------------------
function M.start_unified_creation()
	local creation = require("todo2.creation")
	local context = {
		code_buf = vim.api.nvim_get_current_buf(),
		code_line = vim.fn.line("."),
	}
	creation.start_session(context)
end

-- 状态切换处理器（统一实现）
function M.toggle_task_status()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false

	if line_analysis.info.is_todo_file then
		-- TODO文件中：检测是否为任务行
		if line_analysis.is_todo_task then
			local core = module.get("core")
			core.toggle_line(line_analysis.info.bufnr, vim.fn.line("."))
		else
			should_execute_default = true
		end
	else
		-- 代码文件中：检测是否为标记行
		if line_analysis.is_code_mark then
			local store = get_store_module()
			local link = store.get_todo(line_analysis.id, { verify_line = true })

			if link and link.path then
				local state_manager = module.get("core.state_manager")
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)

				if todo_bufnr == -1 then
					todo_bufnr = vim.fn.bufadd(todo_path)
					vim.fn.bufload(todo_bufnr)
				end

				state_manager.toggle_line(todo_bufnr, link.line or 1)
				return -- 已处理，不执行默认回车
			end
		end

		should_execute_default = true
	end

	-- 如果需要执行默认操作
	if should_execute_default then
		helpers.feedkeys("<CR>")
	end
end

-- 显示状态菜单
function M.show_status_menu()
	local status_module = require("todo2.status")
	status_module.show_status_menu()
end

-- 循环切换状态
function M.cycle_status()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false

	if line_analysis.info.is_todo_file then
		-- TODO文件中：检测是否为任务行
		if line_analysis.is_todo_task then
			local status_module = require("todo2.status")
			status_module.cycle_status()
		else
			should_execute_default = true
		end
	else
		-- 代码文件中：检测是否为标记行
		if line_analysis.is_code_mark then
			local store = get_store_module()
			local link = store.get_todo(line_analysis.id, { verify_line = true })

			if link and link.path then
				local status_module = require("todo2.status")
				local todo_path = vim.fn.fnamemodify(link.path, ":p")
				local todo_bufnr = vim.fn.bufnr(todo_path)

				if todo_bufnr == -1 then
					todo_bufnr = vim.fn.bufadd(todo_path)
					vim.fn.bufload(todo_bufnr)
				end

				-- 保存当前窗口和缓冲区
				local current_bufnr = line_analysis.info.bufnr
				local current_win = line_analysis.info.win_id

				-- 跳转到TODO文件
				vim.cmd("buffer " .. todo_bufnr)

				-- 跳转到对应行
				vim.fn.cursor(link.line or 1, 1)

				-- 执行状态循环切换
				status_module.cycle_status()

				-- 跳回原来的缓冲区和窗口
				if vim.api.nvim_win_is_valid(current_win) then
					vim.api.nvim_set_current_win(current_win)
				end
				if vim.api.nvim_buf_is_valid(current_bufnr) then
					vim.cmd("buffer " .. current_bufnr)
				end
				return -- 已处理，不执行默认Shift+Enter
			end
		end

		should_execute_default = true
	end

	-- 如果需要执行默认操作（Shift+Enter）
	if should_execute_default then
		helpers.feedkeys("<S-CR>")
	end
end

---------------------------------------------------------------------
-- 核心：删除相关处理器
---------------------------------------------------------------------
function M.smart_delete()
	local info = helpers.get_current_buffer_info()
	local mode = vim.fn.mode()

	if info.is_todo_file then
		-- TODO文件中：检测是否为标记行
		local start_lnum, end_lnum

		if mode == "v" or mode == "V" then
			start_lnum = vim.fn.line("v")
			end_lnum = vim.fn.line(".")
			if start_lnum > end_lnum then
				start_lnum, end_lnum = end_lnum, start_lnum
			end
		else
			start_lnum = vim.fn.line(".")
			end_lnum = start_lnum
		end

		local analysis = helpers.analyze_lines(info.bufnr, start_lnum, end_lnum)

		if not analysis.has_markers then
			-- 没有标记：执行默认退格键行为
			helpers.feedkeys("<BS>")
			return
		end

		-- 删除TODO行
		vim.api.nvim_buf_set_lines(info.bufnr, start_lnum - 1, end_lnum, false, {})

		-- 批量删除代码标记
		if #analysis.ids > 0 then
			local deleter = module.get("link.deleter")
			deleter.batch_delete_todo_links(analysis.ids, {
				todo_bufnr = info.bufnr,
				todo_file = info.filename,
			})
		end
	else
		-- 代码文件中：检测是否为标记行
		local line_analysis = helpers.analyze_current_line()

		if line_analysis.is_code_mark then
			-- 是标记行：执行标记删除逻辑
			local deleter = module.get("link.deleter")
			deleter.delete_code_link()
		else
			-- 不是标记行：执行默认退格键行为
			helpers.feedkeys("<BS>")
		end
	end
end

---------------------------------------------------------------------
-- 任务编辑处理器（浮窗多行版）
---------------------------------------------------------------------
function M.edit_task_from_code()
	local line_analysis = helpers.analyze_current_line()
	if not line_analysis.is_code_mark then
		-- ⭐ 非标记行：回退到原生 e 命令
		helpers.feedkeys("e", "n")
		return
	end

	local id = line_analysis.id
	local link_mod = module.get("store.link")
	if not link_mod then
		vim.notify("store.link 模块未加载", vim.log.levels.ERROR)
		return
	end

	local todo_link = link_mod.get_todo(id, { verify_line = true })
	if not todo_link then
		vim.notify("未找到对应的 TODO 链接", vim.log.levels.ERROR)
		return
	end

	local path = todo_link.path
	local line_num = todo_link.line
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines or line_num < 1 or line_num > #lines then
		vim.notify("无法读取 TODO 文件或行号无效", vim.log.levels.ERROR)
		return
	end

	local old_line = lines[line_num]
	local format = require("todo2.utils.format")
	local parsed = format.parse_task_line(old_line)
	if not parsed then
		vim.notify("当前行不是有效的任务行", vim.log.levels.ERROR)
		return
	end

	local input_ui = require("todo2.ui.input")
	input_ui.prompt_multiline({
		title = "Edit Task",
		default = parsed.content or "",
		max_chars = 1000,
		width = 70,
		height = 12,
	}, function(new_content)
		if not new_content or new_content == "" then
			return
		end

		new_content = new_content:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

		if new_content == parsed.content then
			return
		end

		local new_line = format.format_task_line({
			indent = parsed.indent,
			checkbox = parsed.checkbox,
			id = parsed.id,
			tag = parsed.tag,
			content = new_content,
		})

		lines[line_num] = new_line
		local write_ok, write_err = pcall(vim.fn.writefile, lines, path)
		if not write_ok then
			vim.notify("写入 TODO 文件失败: " .. tostring(write_err), vim.log.levels.ERROR)
			return
		end

		local parser = module.get("core.parser")
		if parser then
			parser.invalidate_cache(path)
		end
		local events_mod = module.get("core.events")
		if events_mod then
			events_mod.on_state_changed({
				source = "edit_task_from_code",
				file = path,
				ids = { id },
			})
		end

		vim.notify("✅ 任务内容已更新", vim.log.levels.INFO)
	end)
end

---------------------------------------------------------------------
-- UI相关处理器
---------------------------------------------------------------------

-- 关闭窗口
function M.ui_close_window()
	local win_id = vim.api.nvim_get_current_win()
	helpers.safe_close_window(win_id)
end

-- 刷新显示
function M.ui_refresh()
	local info = helpers.get_current_buffer_info()
	local ui = module.get("ui")
	if ui and ui.refresh then
		ui.refresh(info.bufnr)
		vim.cmd("redraw")
	end
end

-- 新建任务
function M.ui_insert_task()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

-- 新建子任务
function M.ui_insert_subtask()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 2, info.bufnr, module.get("ui"))
end

-- 新建平级任务
function M.ui_insert_sibling()
	local info = helpers.get_current_buffer_info()
	local operations = module.get("ui.operations")
	operations.insert_task("新任务", 0, info.bufnr, module.get("ui"))
end

-- 批量切换任务状态
function M.ui_toggle_selected()
	local info = helpers.get_current_buffer_info()
	local win = vim.fn.bufwinid(info.bufnr)

	if win == -1 then
		vim.notify("未在窗口中找到缓冲区", vim.log.levels.ERROR)
		return 0
	end

	local operations = module.get("ui.operations")
	local changed = operations.toggle_selected_tasks(info.bufnr, win)
	return changed
end

-- 插入模式切换任务状态
function M.ui_toggle_insert()
	helpers.feedkeys("<Esc>", "n")
	local info = helpers.get_current_buffer_info()
	local core = module.get("core")
	core.toggle_line(info.bufnr, vim.fn.line("."))
	helpers.feedkeys("A", "n")
end

---------------------------------------------------------------------
-- 链接相关处理器
---------------------------------------------------------------------

-- 创建链接
function M.create_link()
	module.get("link").create_link()
end

-- 动态跳转（tab按键）
function M.jump_dynamic()
	local line_analysis = helpers.analyze_current_line()
	local should_execute_default = false

	-- 检查是否为标记行
	if line_analysis.is_mark then
		-- 是标记行：执行跳转逻辑
		module.get("link").jump_dynamic()
	else
		-- 不是标记行：执行默认tab行为
		should_execute_default = true
	end

	-- 如果需要执行默认操作
	if should_execute_default then
		helpers.feedkeys("<tab>")
	end
end

-- 预览内容
function M.preview_content()
	local line_analysis = helpers.analyze_current_line()
	local link = module.get("link")

	-- 检测是否为有效的标记行
	if line_analysis.is_mark then
		if line_analysis.info.is_todo_file then
			link.preview_code()
		else
			link.preview_todo()
		end
	else
		-- 如果不是标记行，执行默认的 K 行为
		local info = line_analysis.info
		-- 检查是否安装了 LSP，如果安装了则使用 LSP hover
		if vim.lsp.buf_get_clients(info.bufnr) and #vim.lsp.buf_get_clients(info.bufnr) > 0 then
			vim.lsp.buf.hover()
		else
			-- 没有 LSP，执行原始的 K 键行为
			helpers.feedkeys("K")
		end
	end
end

-- 从代码中创建子任务
function M.create_child_from_code()
	module.get("link.child").create_child_from_code()
end

-- 显示所有双链标记 (QuickFix)
function M.show_project_links_qf()
	module.get("link.viewer").show_project_links_qf()
end

-- 显示当前缓冲区双链标记 (LocList)
function M.show_buffer_links_loclist()
	module.get("link.viewer").show_buffer_links_loclist()
end
---------------------------------------------------------------------
-- 文件管理处理器
---------------------------------------------------------------------

-- 浮窗打开 TODO 文件
function M.open_todo_float()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "float", 1, { enter_insert = false })
		end
	end)
end

-- 水平分割打开 TODO 文件
function M.open_todo_split_horizontal()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "horizontal",
			})
		end
	end)
end

-- 垂直分割打开 TODO 文件
function M.open_todo_split_vertical()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "split", 1, {
				enter_insert = false,
				split_direction = "vertical",
			})
		end
	end)
end

-- 编辑模式打开 TODO 文件
function M.open_todo_edit()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.open_todo_file(choice.path, "edit", 1, { enter_insert = false })
		end
	end)
end

-- 创建 TODO 文件
function M.create_todo_file()
	module.get("ui").create_todo_file()
end

-- 删除 TODO 文件
function M.delete_todo_file()
	local ui = module.get("ui")
	ui.select_todo_file("current", function(choice)
		if choice then
			ui.delete_todo_file(choice.path)
		end
	end)
end

---------------------------------------------------------------------
-- 链式标记处理器
---------------------------------------------------------------------

-- 从代码中创建链式标记
function M.create_chain_from_code()
	local chain_module = module.get("link.chain")
	if chain_module and chain_module.create_chain_from_code then
		chain_module.create_chain_from_code()
	else
		vim.notify("链式标记模块未加载", vim.log.levels.ERROR)
	end
end

---------------------------------------------------------------------
-- 工具函数：获取所有处理器
---------------------------------------------------------------------
function M.get_all_handlers()
	return M
end

return M
