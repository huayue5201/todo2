-- lua/todo2/link/renderer.lua
--- @module todo2.link.renderer
--- @brief 在代码文件中渲染 TODO 状态（☐ / ✓），并显示状态文本
---
--- 设计目标：
--- 1. 渲染必须稳定、幂等、无闪烁
--- 2. 与 store.lua 完全对齐（路径规范化、force_relocate）
--- 3. 避免重复 extmark、避免错位
--- 4. 文件不存在时安全退出
--- 5. 所有函数带 LuaDoc 注释

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("todo2_code_status")

---------------------------------------------------------------------
-- 工具函数：读取 TODO 文件中的状态
---------------------------------------------------------------------

--- 从 TODO 文件中读取状态（☐ / ✓）
---
--- @param todo_path string
--- @param line integer
--- @return string|nil icon, string|nil text, string|nil hl_group
local function read_todo_status(todo_path, line)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	if vim.fn.filereadable(todo_path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		return nil
	end

	local todo_line = lines[line]
	if not todo_line then
		return nil
	end

	local status = todo_line:match("%[(.)%]")
	if not status then
		return nil
	end

	if status == "x" or status == "X" then
		return "✓", "已完成", "String"
	else
		return "☐", "未完成", "Error"
	end
end

---------------------------------------------------------------------
-- 主函数：渲染代码状态
---------------------------------------------------------------------

--- 在代码文件中渲染 TODO 状态（行尾虚拟文本）
---
--- @param bufnr integer
--- @return nil
function M.render_code_status(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 清除旧渲染
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines then
		return
	end

	for i, line in ipairs(lines) do
		local id = line:match("TODO:ref:(%w+)")
		if id then
			-- 获取 TODO 链接（自动重新定位）
			local link = get_store().get_todo_link(id, { force_relocate = true })
			if link then
				local icon, text, hl = read_todo_status(link.path, link.line)
				if icon then
					-- 设置虚拟文本
					vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, -1, {
						virt_text = {
							{ "  " .. icon .. " " .. text, hl },
						},
						virt_text_pos = "eol",
						hl_mode = "combine",
						right_gravity = false,
						priority = 100,
					})
				end
			end
		end
	end
end

return M
