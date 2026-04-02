-- lua/todo2/creation/actions/parent.lua
-- 独立任务创建动作（无父任务）
---@module "todo2.creation.actions.parent"

local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local buffer = require("todo2.utils.buffer")

---独立任务创建动作
---@param context table 创建上下文
---@param target table 目标位置信息
---@return boolean, string
return function(context, target)
	local id = id_utils.generate_id()
	if not id_utils.is_valid(id) then
		return false, "生成的ID格式无效"
	end

	local content = "新任务"
	local tag = context.selected_tag or "TODO"

	-- 1. 插入TODO行
	-- NOTE:ref:79698c
	local result = service.insert_task_line(target.bufnr, target.line, {
		id = id,
		content = content,
		tag = tag,
		update_store = true,
		autosave = true,
	})

	if not result then
		return false, "插入任务行失败"
	end

	local new_line = result.line_num

	-- 2. 校验代码行号
	if not buffer.is_valid_line(context.code_buf, context.code_line) then
		return false, string.format("代码行号无效：%d", context.code_line)
	end

	-- 3. 创建代码链接（自动插入代码标记和上下文）
	service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 4. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 独立任务 %s 创建成功", id)
end