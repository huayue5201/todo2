-- lua/todo2/creation/actions/parent.lua
local link_service = require("todo2.creation.service")
local link_utils = require("todo2.link.utils")
local link = require("todo2.link") -- 用于 generate_id

return function(context, target)
	local id = link.generate_id()
	local content = "新任务"
	local tag = context.selected_tag or "TODO"

	-- 1. 在 TODO 文件中插入任务行
	-- 使用 target.line 实现在当前行**之后**插入（更符合直觉）
	local new_line_num = link_service.insert_task_line(target.bufnr, target.line, {
		id = id,
		tag = tag,
		content = content,
		update_store = true,
		autosave = true,
	})
	if not new_line_num then
		return false, "插入任务行失败"
	end

	-- 2. 在代码中插入标记
	link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag)

	-- 3. 创建代码链接
	link_service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 4. 光标定位到新任务行末尾，进入插入模式
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line_num, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 独立任务 %s 创建成功", id)
end
