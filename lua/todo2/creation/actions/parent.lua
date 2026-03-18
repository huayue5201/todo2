-- lua/todo2/creation/actions/parent.lua
-- 独立任务创建动作（无父任务）
---@module "todo2.creation.actions.parent"
---@param context table 创建上下文
---@param target table 目标位置信息
---@return boolean success 是否成功
---@return string message 结果消息

local service = require("todo2.creation.service")
local link_utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")

---校验行号是否有效
---@param bufnr number 缓冲区号
---@param line number 行号
---@return boolean
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total
end

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
	print("🪚 tag: " .. tostring(tag))

	-- 1. 插入TODO行（传递tag）
	local new_line = service.insert_task_line(target.bufnr, target.line, {
		id = id,
		content = content,
		tag = tag, -- ⭐ 传递用户选择的标签
		update_store = true,
		autosave = true,
	})
	if not new_line then
		return false, "插入任务行失败"
	end

	-- 2. 校验代码行号
	if not validate_line_number(context.code_buf, context.code_line) then
		return false, string.format("代码行号无效：%d", context.code_line)
	end

	-- 3. 插入代码标记（使用增强的缩进功能）
	local ok = link_utils.insert_code_tag_above(context.code_buf, context.code_line, id, tag, {
		preserve_indent = true,
	})
	if not ok then
		return false, "插入代码标记失败"
	end

	-- 4. 创建代码链接
	service.create_code_link(context.code_buf, context.code_line, id, content, tag)

	-- 5. 光标定位
	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, string.format("✅ 独立任务 %s 创建成功", id)
end
