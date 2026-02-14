-- lua/todo/link/utils.lua
local M = {}

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local comment = require("todo2.utils.comment")

---------------------------------------------------------------------
function M.find_task_insert_position(lines)
	for i, line in ipairs(lines) do
		if line:match("^%s*[-*]%s+%[[ xX]%]") then
			return i
		end
	end

	for i, line in ipairs(lines) do
		if line:match("^#+ ") then
			for j = i + 1, #lines do
				if lines[j] == "" then
					return j + 1
				end
			end
			return i + 1
		end
	end

	return 1
end

---------------------------------------------------------------------
-- 统一：在代码 buffer 中将 TODO 标记插入到"上一行"
---------------------------------------------------------------------
-- 使用 comment 模块获取注释前缀和生成标记
function M.insert_code_tag_above(bufnr, row, id, tag)
	-- 使用 comment 模块生成完整的标记行
	tag = tag or "TODO"
	local tag_line = comment.generate_marker(id, tag, bufnr)

	-- 在 row-1 的位置插入新行（上一行）
	vim.api.nvim_buf_set_lines(bufnr, row - 1, row - 1, false, { tag_line })
end

---------------------------------------------------------------------
-- 检查是否在 TODO 浮动窗口中
---------------------------------------------------------------------
function M.is_todo_floating_window(win_id)
	win_id = win_id or vim.api.nvim_get_current_win()

	if not vim.api.nvim_win_is_valid(win_id) then
		return false
	end

	local win_config = vim.api.nvim_win_get_config(win_id)
	local is_float = win_config.relative ~= ""

	if not is_float then
		return false
	end

	-- 检查buffer是否是TODO文件
	local bufnr = vim.api.nvim_win_get_buf(win_id)
	local bufname = vim.api.nvim_buf_get_name(bufnr)

	return bufname:match("%.todo%.md$") or bufname:match("todo")
end

return M
