-- lua/todo2/link/child.lua
--- @module todo2.child

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 配置模块
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- ⭐ 标签管理器（新增）
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- 状态管理
---------------------------------------------------------------------
local selecting_parent = false
local pending = {
	code_buf = nil,
	code_row = nil,
	selected_tag = nil, -- 保存选择的标签
}

---------------------------------------------------------------------
-- 清理状态
---------------------------------------------------------------------
local function cleanup_state()
	selecting_parent = false
	pending.code_buf = nil
	pending.code_row = nil
	pending.selected_tag = nil
end

---------------------------------------------------------------------
-- ⭐ 使用 parser 准确判断任务行
---------------------------------------------------------------------
local function get_parsed_task_at_line(bufnr, row)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" or not path:match("%.todo%.md$") then
		return nil
	end

	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	local tasks, _ = parser.parse_file(path)
	if not tasks then
		return nil
	end

	for _, task in ipairs(tasks) do
		if task.line_num == row then
			return task
		end
	end

	return nil
end

---------------------------------------------------------------------
-- ⭐ 选择标签类型
---------------------------------------------------------------------
local function select_tag_type(todo_file_selection_callback)
	-- 从配置中获取标签
	local tags = config.get("tags") or {}
	local tag_choices = {}

	for tag, style in pairs(tags) do
		table.insert(tag_choices, {
			tag = tag,
			icon = style.icon or "",
			display = string.format("%s  %s", style.icon or "", tag),
		})
	end

	-- 如果标签为空，添加默认选项
	if #tag_choices == 0 then
		table.insert(tag_choices, {
			tag = "TODO",
			icon = "",
			display = "TODO",
		})
	end

	vim.ui.select(tag_choices, {
		prompt = "🏷️ 选择子任务标签类型：",
		format_item = function(item)
			return item.display
		end,
	}, function(tag_item)
		if not tag_item then
			cleanup_state()
			return
		end

		pending.selected_tag = tag_item.tag
		todo_file_selection_callback()
	end)
end

---------------------------------------------------------------------
-- ⭐ 创建子任务
---------------------------------------------------------------------
function M.create_child_from_code()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]

	-- 检查是否已有TAG
	if line and line:match("%u+:ref:%w+") then
		vim.notify("当前行已有TAG标记，请选择其他位置", vim.log.levels.WARN)
		return
	end

	-- 保存代码位置
	pending.code_buf = bufnr
	pending.code_row = row

	-- 先选择标签类型
	select_tag_type(function()
		-- 获取TODO文件列表
		local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
		local file_manager = module.get("ui.file_manager")
		local files = file_manager.get_todo_files(project)

		if #files == 0 then
			vim.notify("当前项目没有TODO文件", vim.log.levels.WARN)
			cleanup_state()
			return
		end

		-- 选择TODO文件
		local choices = {}
		for _, f in ipairs(files) do
			table.insert(choices, {
				project = project,
				path = f,
				display = vim.fn.fnamemodify(f, ":t"),
			})
		end

		vim.ui.select(choices, {
			prompt = "🗂️ 选择 TODO 文件：",
			format_item = function(item)
				return string.format("%-20s • %s", item.project or project, vim.fn.fnamemodify(item.path, ":t"))
			end,
		}, function(choice)
			if not choice then
				cleanup_state()
				return
			end

			local ui = module.get("ui")
			local todo_buf, todo_win = ui.open_todo_file(choice.path, "float", nil, {
				enter_insert = false,
				focus = true,
			})

			if not todo_buf or not todo_win then
				vim.notify("无法打开TODO文件", vim.log.levels.ERROR)
				cleanup_state()
				return
			end

			selecting_parent = true
			vim.notify("请选择父任务，然后按<CR>创建子任务", vim.log.levels.INFO)

			-- 设置临时键位
			local function clear_temp_maps()
				vim.keymap.del("n", "<CR>", { buffer = todo_buf })
				vim.keymap.del("n", "<ESC>", { buffer = todo_buf })
			end

			vim.keymap.set("n", "<CR>", function()
				if selecting_parent then
					M.on_cr_in_todo()
					clear_temp_maps()
				else
					vim.cmd("normal! <CR>")
				end
			end, { buffer = todo_buf, noremap = true, silent = true, desc = "选择父任务并创建子任务" })

			vim.keymap.set("n", "<ESC>", function()
				selecting_parent = false
				cleanup_state()
				vim.notify("已取消创建子任务", vim.log.levels.INFO)
				clear_temp_maps()
			end, { buffer = todo_buf, noremap = true, silent = true, desc = "取消创建子任务" })
		end)
	end)
end

---------------------------------------------------------------------
-- ⭐ 在 TODO 浮窗中按 <CR>
---------------------------------------------------------------------
function M.on_cr_in_todo()
	if not selecting_parent then
		return
	end

	-- 保存当前浮窗信息
	local float_win = vim.api.nvim_get_current_win()
	local tbuf = vim.api.nvim_get_current_buf()
	local trow = vim.api.nvim_win_get_cursor(0)[1]

	-- 1. 使用 parser 准确判断当前行是否是任务行
	local parent_task = get_parsed_task_at_line(tbuf, trow)
	if not parent_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return
	end

	-- 2. 确保父任务有 ID
	local operations = module.get("ui.operations")
	if not operations then
		vim.notify("无法获取操作模块", vim.log.levels.ERROR)
		return
	end

	local parent_id = operations.ensure_task_id(tbuf, trow, parent_task)
	if not parent_id then
		vim.notify("无法为父任务生成 ID", vim.log.levels.ERROR)
		return
	end

	-- 3. 生成子任务 ID
	local link_module = module.get("link")
	local new_id = link_module.generate_id()

	-- 4. 插入子任务
	local link_service = module.get("link.service")
	if not link_service then
		vim.notify("无法获取链接服务模块", vim.log.levels.ERROR)
		return
	end

	-- ⭐ 修改：内容应该是纯文本
	local child_content = "新任务" -- 纯文本内容

	local child_row = link_service.create_child_task(tbuf, parent_task, new_id, child_content, pending.selected_tag)

	if not child_row then
		vim.notify("无法创建子任务", vim.log.levels.ERROR)
		return
	end

	-- 5. 在代码中插入TAG（使用选择的标签）
	if pending.code_buf and pending.code_row and pending.selected_tag then
		local utils = module.get("link.utils")
		utils.insert_code_tag_above(pending.code_buf, pending.code_row, new_id, pending.selected_tag)

		-- 使用统一服务创建代码链接（传递标签）
		local link_service = module.get("link.service")
		-- ⭐ 修改：传递清理后的内容到存储
		local cleaned_content = tag_manager.clean_content(child_content, pending.selected_tag)
		link_service.create_code_link(pending.code_buf, pending.code_row, new_id, cleaned_content, pending.selected_tag)
	else
		vim.notify("创建子任务失败：缺少必要参数", vim.log.levels.ERROR)
		return
	end

	-- 6. 清理状态
	cleanup_state()

	-- 7. 确保回到正确的窗口
	if vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_set_current_win(float_win)

		if vim.api.nvim_win_get_buf(float_win) ~= tbuf then
			vim.api.nvim_win_set_buf(float_win, tbuf)
		end

		-- 定位光标到新行行尾并进入插入模式
		local col = vim.fn.col("$") - 1
		vim.api.nvim_win_set_cursor(float_win, { child_row, col })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
	end

	vim.notify(
		string.format("子任务 %s 创建成功（标签：%s）", new_id, pending.selected_tag),
		vim.log.levels.INFO
	)
end

return M
