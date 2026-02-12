-- lua/todo2/creation/actions/child.lua
local link_service = require("todo2.creation.service")
local link_utils = require("todo2.link.utils")
local link = require("todo2.link")
local parser = require("todo2.core.parser")

return function(context, target)
	-- 1. 获取父任务
	local path = vim.api.nvim_buf_get_name(target.bufnr)
	local tasks = parser.parse_file(path)
	local parent_task = nil
	for _, t in ipairs(tasks) do
		if t.line_num == target.line then
			parent_task = t
			break
		end
	end
	if not parent_task then
		return false, "当前行不是有效任务"
	end

	local id = link.generate_id()
	local content = "子任务"
	local tag = context.selected_tag or "TODO"

	-- 2. 创建子任务（复用 link.service.create_child_task）
	local child_line = link_service.create_child_task(target.bufnr, parent_task, id, content, tag)
	if not child_line then
		return false, "创建子任务失败"
	end

	-- 3. 插入代码标记
	link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag)
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 4. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { child_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 子任务 %s 创建成功", id)
end
