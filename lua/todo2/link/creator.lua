-- lua/todo2/link/creator.lua
--- @module todo2.link.creator
--- @brief 创建代码 ↔ TODO 双链（插入 TODO:ref:id 与 {#id}）
---
--- 设计目标：
--- 1. 创建链接必须是幂等、安全、可回滚
--- 2. 与 store.lua 完全对齐（路径规范化、索引更新）
--- 3. 插入位置稳定、行号一致
--- 4. 用户取消选择时必须完全回滚
--- 5. 所有函数带 LuaDoc 注释

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

--- 在 TODO 文件中插入任务行，并写入 store
---
--- @param todo_path string TODO 文件绝对路径
--- @param id string 唯一 ID
--- @return nil
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
-- 主函数：创建链接
---------------------------------------------------------------------

--- 创建代码 ↔ TODO 双链
--- 1. 在代码中插入 TODO:ref:id
--- 2. 写入 store（code_link）
--- 3. 选择 TODO 文件
--- 4. 插入 {#id} 任务
--- 5. 用户取消时回滚
---
--- @return nil
function M.create_link()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	local lnum = vim.fn.line(".")

	if file_path == "" then
		vim.notify("无法创建链接：当前 buffer 没有文件路径", vim.log.levels.ERROR)
		return
	end

	-- 生成唯一 ID
	local id = get_utils().generate_id()

	-- 在代码中插入 TODO:ref:id
	local comment = get_utils().get_comment_prefix()
	local insert_line = string.format("%s TODO:ref:%s", comment, id)

	-- 插入到下一行（保持一致性）
	vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { insert_line })

	-- 写入 store（代码 → TODO）
	get_store().add_code_link(id, {
		path = file_path,
		line = lnum + 1,
		content = "",
		created_at = os.time(),
	})

	-----------------------------------------------------------------
	-- 选择 TODO 文件
	-----------------------------------------------------------------

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = get_file_manager().get_todo_files(project)

	local choices = {}

	-- 已有 TODO 文件
	for _, f in ipairs(todo_files) do
		table.insert(choices, {
			type = "existing",
			path = f,
			display = vim.fn.fnamemodify(f, ":t"),
			project = project,
		})
	end

	-- 新建 TODO 文件
	table.insert(choices, {
		type = "new",
		path = nil,
		display = "新建 TODO 文件",
		project = project,
	})

	-- 如果没有 TODO 文件，提示用户
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
			if item.type == "existing" then
				return string.format("📄 %s", item.display)
			elseif item.type == "new" then
				return "🆕 新建 TODO 文件"
			else
				return "ℹ️ " .. item.display
			end
		end,
	}, function(choice)
		-- 用户取消选择
		if not choice then
			-- 回滚：删除插入的代码行
			vim.api.nvim_buf_set_lines(bufnr, lnum, lnum + 1, false, {})
			-- 删除 store 中的 code_link
			get_store().delete_code_link(id)
			vim.notify("已取消创建链接", vim.log.levels.INFO)
			return
		end

		-- 新建 TODO 文件
		if choice.type == "new" then
			local new_file = get_ui().create_todo_file()
			if new_file then
				add_task_to_todo_file(new_file, id)
			else
				-- 回滚
				vim.api.nvim_buf_set_lines(bufnr, lnum, lnum + 1, false, {})
				get_store().delete_code_link(id)
			end
			return
		end

		-- 选择已有 TODO 文件
		if choice.type == "existing" then
			add_task_to_todo_file(choice.path, id)
			return
		end
	end)
end

return M
