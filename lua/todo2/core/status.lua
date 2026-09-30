-- lua/todo2/core/status.lua
-- 状态领域逻辑：唯一的循环状态定义来源 + 状态写入。
-- 活跃状态（循环状态）由用户通过 config.status.cycle 定义；
-- completed / archived 为固定终态，不可循环，统一灰 + 删除线。

local M = {}

local config = require("todo2.config")
local types = require("todo2.store.types")
local core = require("todo2.store.task.core")

---------------------------------------------------------------------
-- 固定终态显示定义
---------------------------------------------------------------------
local TERMINAL_DEFS = {
	[types.STATUS.COMPLETED] = { label = "完成", icon = "", color = "#868e96" },
	[types.STATUS.ARCHIVED] = { label = "归档", icon = "📦", color = "#868e96" },
}

---------------------------------------------------------------------
-- 循环状态读取
---------------------------------------------------------------------

--- 获取用户配置的循环状态列表（顺序即循环顺序）
---@return table[]
function M.get_cycle()
	return config.get("status.cycle") or {}
end

--- 获取默认状态（第一个循环状态）
---@return string|nil
function M.get_default()
	return config.get_default_status()
end

--- 获取状态定义（label / icon / color）
---@param status string
---@return table|nil
function M.get_definition(status)
	if not status then
		return nil
	end

	if TERMINAL_DEFS[status] then
		return TERMINAL_DEFS[status]
	end

	for _, def in ipairs(M.get_cycle()) do
		if def.label == status then
			return def
		end
	end

	return nil
end

--- 获取状态高亮组名（TodoStatus<Label>）
---@param status string
---@return string|nil
function M.get_hl_group(status)
	local def = M.get_definition(status)
	if not def then
		return nil
	end
	return "TodoStatus" .. status:gsub("^%l", string.upper)
end

--- 获取内容高亮组：完成/归档统一灰 + 删除线，活跃用状态色
---@param status string
---@return string
function M.get_content_hl(status)
	if types.is_completed_status(status) then
		return "TodoStrikethrough"
	end
	return M.get_hl_group(status) or "Normal"
end

---------------------------------------------------------------------
-- 循环 / checkbox
---------------------------------------------------------------------

--- 获取下一个循环状态
---@param current string
---@return string|nil
function M.get_next(current)
	local c = M.get_cycle()
	for i, def in ipairs(c) do
		if def.label == current then
			return c[i % #c + 1].label
		end
	end
	return M.get_default()
end

--- checkbox 转状态（活跃 checkbox 返回默认状态）
---@param checkbox string
---@return string|nil
function M.resolve_checkbox(checkbox)
	return types.checkbox_to_status((checkbox or ""):lower()) or M.get_default()
end

---------------------------------------------------------------------
-- 状态写入
---------------------------------------------------------------------

--- 纯数据更新：写存储 + 触发事件
---@param id string
---@param target_status string
---@param source string|nil
---@param opts table|nil
function M.update(id, target_status, source, opts)
	opts = opts or {}
	source = source or "status_update"

	local task = core.get_task(id)
	if not task then
		return false, "找不到任务: " .. tostring(id)
	end

	-- 终态不参与状态切换（含 cycle 与菜单）
	if types.is_completed_status(task.core.status) then
		return false, "完成/归档的任务不能切换状态"
	end

	task.core.status = target_status
	task.timestamps.updated = os.time()

	core.save_task(id, task)

	if not opts.skip_event then
		-- 惰性 require，避免模块加载期与 events → scheduler → conceal 形成循环依赖
		local events = require("todo2.core.events")
		events.emit(source, {
			changed_ids = { id },
			ids = { id },
			files = {},
		})
	end

	return true, "ok"
end

--- 进入终态（completed / archived）：记住之前的活跃状态
---@param task table
---@param target_status string COMPLETED 或 ARCHIVED
---@param now? number
function M.enter_terminal(task, target_status, now)
	now = now or os.time()
	task.core.previous_status = task.core.status
	task.core.status = target_status
	task.timestamps.updated = now
	if target_status == types.STATUS.COMPLETED then
		task.timestamps.completed = now
	elseif target_status == types.STATUS.ARCHIVED then
		task.timestamps.archived = now
	end
end

--- 退出终态：恢复为活跃状态
---@param task table
---@param restore_status? string 优先使用的恢复状态（如快照中的状态）
---@param now? number
function M.exit_terminal(task, restore_status, now)
	if not types.is_completed_status(task.core.status) then
		return
	end
	now = now or os.time()
	task.core.status = restore_status or task.core.previous_status or M.get_default()
	task.core.previous_status = nil
	task.timestamps.completed = nil
	task.timestamps.archived = nil
	task.timestamps.updated = now
end

--- 循环切换状态（UI 调用）
---@param id string
function M.cycle(id)
	local task = core.get_task(id)
	if not task then
		return false, "找不到任务"
	end

	if types.is_completed_status(task.core.status) then
		return false, "完成/归档的任务不能切换状态"
	end

	return M.update(id, M.get_next(task.core.status), "cycle")
end

return M
