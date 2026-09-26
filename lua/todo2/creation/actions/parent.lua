-- lua/todo2/creation/actions/parent.lua
-- 独立任务创建动作（无父任务）
---@module "todo2.creation.actions.parent"

local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local operations = require("todo2.creation.actions.operations")

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

	-- 1. 插入TODO行
	local result = service.insert_task_line(target.bufnr, target.line, {
		id = id,
		content = content,
		update_store = true,
		autosave = true,
	})

	if not result then
		return false, "插入任务行失败"
	end

	local new_line = result.line_num

	local ok, err = operations.finish_creation(context, target, id, content, new_line)
	if not ok then
		return false, err
	end

	return true, string.format("✅ 独立任务 %s 创建成功", id)
end

