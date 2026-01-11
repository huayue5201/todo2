-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链（延迟插入、可回滚、自动保存）

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local utils
local ui
local file_manager

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local function get_utils()
	if not utils then
		utils = require("todo2.link.utils")
	end
	return utils
end

local function get_ui()
	if not ui then
		ui = require("todo2.ui")
	end
	return ui
end

local function get_file_manager()
	if not file_manager then
		file_manager = require("todo2.ui.file_manager")
	end
	return file_manager
end

---------------------------------------------------------------------
-- 内部函数：向 TODO 文件插入任务
---------------------------------------------------------------------

local function add_task_to_todo_file(todo_path, id)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	-- 读取文件
	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		vim.notify("无法读取 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	-- 找到插入位置
	local insert_line = get_utils().find_task_insert_position(lines)

	-- 插入任务
	local task_line = string.format("- [ ] {#%s} 新任务", id)
	table.insert(lines, insert_line, task_line)

	-- 写回文件
	local fd = io.open(todo_path, "w")
	if not fd then
		vim.notify("无法写入 TODO 文件", vim.log.levels.ERROR)
		return
	end
	fd:write(table.concat(lines, "\n"))
	fd:close()

	-- 写入 store（TODO → 代码）
	get_store().add_todo_link(id, {
		path = todo_path,
		line = insert_line,
		content = "新任务",
		created_at = os.time(),
	})

	-- 打开 TODO 文件（浮窗）
	get_ui().open_todo_file(todo_path, "float", insert_line, {
		enter_insert = true,
	})

	vim.notify("已创建 TODO 链接: " .. id, vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- ⭐ 主函数：创建链接（延迟插入 + 可回滚 + 自动保存）
---------------------------------------------------------------------

function M.create_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lnum = vim.fn.line(".")

	if file_path == "" then
		vim.notify("无法创建链接：当前 buffer 没有文件路径", vim.log.levels.ERROR)
		return
	end

	-- 生成唯一 ID（但不插入）
	local id = get_utils().generate_id()

	-----------------------------------------------------------------
	-- 选择 TODO 文件（延迟插入）
	-----------------------------------------------------------------

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = get_file_manager().get_todo_files(project)

	local choices = {}

	for _, f in ipairs(todo_files) do
		table.insert(choices, {
			type = "existing",
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
			project = project,
		})
	end

	table.insert(choices, {
		type = "new",
		path = nil,
		display = "🆕 新建 TODO 文件",
		project = project,
	})

	if #todo_files == 0 then
		table.insert(choices, {
			type = "info",
			path = nil,
			display = "当前项目没有 TODO 文件，请新建一个",
			project = project,
		})
	end

	-----------------------------------------------------------------
	-- 显示选择框
	-----------------------------------------------------------------

	vim.ui.select(choices, {
		prompt = "选择 TODO 文件",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		-- ❌ 用户取消 → 不插入任何标记
		if not choice or choice.type == "info" then
			return
		end

		-----------------------------------------------------------------
		-- ⭐ 用户确认后才插入代码标记
		-----------------------------------------------------------------

		local comment = get_utils().get_comment_prefix()
		local insert_line = string.format("%s TODO:ref:%s", comment, id)

		-- 插入到下一行
		vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { insert_line })

		-- 写入 store（代码 → TODO）
		get_store().add_code_link(id, {
			path = file_path,
			line = lnum + 1,
			content = "",
			created_at = os.time(),
		})

		-- 自动保存代码文件
		vim.cmd("write")

		-----------------------------------------------------------------
		-- 插入 TODO 文件标记
		-----------------------------------------------------------------

		if choice.type == "existing" then
			add_task_to_todo_file(choice.path, id)
		elseif choice.type == "new" then
			get_file_manager().create_new_todo_file(project, function(new_path)
				add_task_to_todo_file(new_path, id)
			end)
		end

		-----------------------------------------------------------------
		-- 自动刷新渲染
		-----------------------------------------------------------------

		vim.schedule(function()
			local renderer = require("todo2.link.renderer")
			renderer.render_code_status(bufnr)
		end)
	end)
end

return M
