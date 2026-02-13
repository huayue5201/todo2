-- lua/todo2/core/init.lua
--- @module todo2.core
--- @brief 精简版核心模块入口（适配原子性操作）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local stats = require("todo2.core.stats")
local autosave = require("todo2.core.autosave")
local archive = require("todo2.core.archive")
local status_mod = require("todo2.core.status")
local store = require("todo2.store")

---------------------------------------------------------------------
-- 模块依赖声明（用于文档）
---------------------------------------------------------------------
M.dependencies = {
	"config",
	"core.parser",
	"core.state_manager",
	"core.stats",
	"core.events",
	"core.autosave",
	"core.archive",
	"core.status",
}

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	-- core 模块不需要特别的初始化工作
	return M
end

---------------------------------------------------------------------
-- 精简API：直接暴露子模块功能
---------------------------------------------------------------------

-- 解析文件
function M.parse_file(path)
	return parser.parse_file(path)
end

-- 计算统计
function M.calculate_all_stats(tasks)
	return stats.calculate_all_stats(tasks)
end

function M.summarize(lines, path)
	return stats.summarize(lines, path)
end

-- 清理缓存
function M.clear_cache()
	parser.invalidate_cache()
end

---------------------------------------------------------------------
-- 核心状态管理API（适配原子性操作）
---------------------------------------------------------------------

--- 更新活跃状态（两端同时更新）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_active_status(id, new_status, source)
	return status_mod.update_active_status(id, new_status, source)
end

--- 标记任务为完成（两端同时标记）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.mark_completed(id)
	if not store or not store.link then
		return false
	end
	return store.link.mark_completed(id) ~= nil
end

--- 重新打开任务（两端同时重新打开）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.reopen_link(id)
	if not store or not store.link then
		return false
	end
	return store.link.reopen_link(id) ~= nil
end

--- 验证状态流转
--- @param current_status string 当前状态
--- @param target_status string 目标状态
--- @return boolean 是否可以切换
function M.is_valid_transition(current_status, target_status)
	return status_mod.is_valid_transition(current_status, target_status)
end

--- 获取可用的状态流转列表
--- @param current_status string 当前状态
--- @return table 可用状态列表
function M.get_available_transitions(current_status)
	return status_mod.get_available_transitions(current_status)
end

--- 判断状态是否可手动切换
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	return status_mod.is_user_switchable(status)
end

--- 获取下一个状态
--- @param current_status string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string 下一个状态
function M.get_next_status(current_status, include_completed)
	return status_mod.get_next_status(current_status, include_completed)
end

--- 获取当前行的链接信息（纯数据查询）
--- @return table|nil
function M.get_current_link_info()
	return status_mod.get_current_link_info()
end

---------------------------------------------------------------------
-- 自动保存API
---------------------------------------------------------------------
function M.request_autosave(bufnr)
	return autosave.request_save(bufnr)
end

function M.flush_autosave(bufnr)
	return autosave.flush(bufnr)
end

return M
