-- lua/todo2/link/service.lua
--- @module todo2.link.service
--- @brief 统一的链接创建和管理服务

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 提取上下文信息
--- @param bufnr number buffer编号
--- @param line number 行号（1-based）
--- @return table 上下文信息
local function extract_context(bufnr, line)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prev = line > 1 and lines[line - 2] or ""
	local curr = lines[line - 1] or ""
	local next = line < #lines and lines[line] or ""

	return {
		prev = prev,
		curr = curr,
		next = next,
	}
end

--- 创建代码链接（统一实现）
--- @param bufnr number buffer编号
--- @param line number 行号（1-based）
--- @param id string 任务ID
--- @param content string|nil 内容
--- @return boolean 是否成功
function M.create_code_link(bufnr, line, id, content)
	if not bufnr or not line or not id then
		return false
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false
	end

	content = content or ""

	-- 提取上下文
	local context = extract_context(bufnr, line)

	-- 调用存储
	local store = module.get("store")
	local success = store.add_code_link(id, {
		path = path,
		line = line, -- 统一使用 1-based 行号
		content = content,
		created_at = os.time(),
		context = context,
	})

	if not success then
		return false
	end

	-- 触发事件
	local events = module.get("core.events")
	if events and events.on_state_changed then
		events.on_state_changed({
			source = "create_code_link",
			file = path,
			bufnr = bufnr,
			ids = { id },
		})
	end

	-- 自动保存
	local autosave = module.get("core.autosave")
	if autosave then
		autosave.request_save(bufnr)
	end

	return true
end

--- 创建TODO链接（统一实现）
--- @param path string 文件路径
--- @param line number 行号（1-based）
--- @param id string 任务ID
--- @param content string 内容
--- @return boolean 是否成功
function M.create_todo_link(path, line, id, content)
	if not path or not line or not id then
		return false
	end

	content = content or "新任务"

	-- 调用存储
	local store = module.get("store")
	local success = store.add_todo_link(id, {
		path = path,
		line = line, -- 统一使用 1-based 行号
		content = content,
		created_at = os.time(),
	})

	if not success then
		return false
	end

	return true
end

--- 插入TODO任务到文件（统一实现）
--- @param todo_path string TODO文件路径
--- @param id string 任务ID
--- @param task_content string|nil 任务内容
--- @return number|nil 插入的行号（1-based）
function M.insert_task_to_todo_file(todo_path, id, task_content)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	-- 加载TODO文件buffer
	local bufnr = vim.fn.bufnr(todo_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("无法加载 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return nil
	end

	-- 获取当前行内容
	local link_utils = module.get("link.utils")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = link_utils.find_task_insert_position(lines)

	-- 插入任务行
	local content = task_content or "新任务"
	local task_line = string.format("- [ ] {#%s} %s", id, content)
	vim.api.nvim_buf_set_lines(bufnr, insert_line - 1, insert_line - 1, false, { task_line })

	-- 创建TODO链接
	M.create_todo_link(todo_path, insert_line, id, content)

	-- 自动保存
	local autosave = module.get("core.autosave")
	if autosave then
		autosave.request_save(bufnr)
	end

	return insert_line
end

return M
