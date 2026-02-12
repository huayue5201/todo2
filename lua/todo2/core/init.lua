-- lua/todo2/core/init.lua
--- @module todo2.core
--- @brief 精简版核心模块入口（适配原子性操作）

local M = {}

---------------------------------------------------------------------
-- 模块懒加载
---------------------------------------------------------------------
local module = require("todo2.module")

-- 按需加载子模块
local function load_module(name)
	return module.get(name)
end

---------------------------------------------------------------------
-- 模块依赖声明
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
-- 检查并加载依赖
---------------------------------------------------------------------
local function load_dependencies()
	for _, dep in ipairs(M.dependencies) do
		if not module.is_loaded(dep) then
			module.get(dep)
		end
	end
end

---------------------------------------------------------------------
-- 模块初始化
---------------------------------------------------------------------
function M.setup()
	load_dependencies()
	-- core 模块不需要特别的初始化工作
	return M
end

---------------------------------------------------------------------
-- 精简API：直接暴露子模块功能
---------------------------------------------------------------------

-- 解析文件
function M.parse_file(path)
	load_dependencies()
	local parser = load_module("core.parser")
	return parser.parse_file(path)
end

-- 切换任务状态（核心功能，保留）
function M.toggle_line(bufnr, lnum, opts)
	load_dependencies()
	local state_manager = load_module("core.state_manager")
	return state_manager.toggle_line(bufnr, lnum, opts)
end

-- 刷新任务树
function M.refresh(bufnr)
	load_dependencies()
	local state_manager = load_module("core.state_manager")
	return state_manager.refresh(bufnr)
end

-- 计算统计
function M.calculate_all_stats(tasks)
	load_dependencies()
	local stats = load_module("core.stats")
	return stats.calculate_all_stats(tasks)
end

function M.summarize(lines, path)
	load_dependencies()
	local stats = load_module("core.stats")
	return stats.summarize(lines, path)
end

-- 清理缓存
function M.clear_cache()
	load_dependencies()
	local parser = load_module("core.parser")
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
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.update_active_status(id, new_status, source)
end

--- 标记任务为完成（两端同时标记）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.mark_completed(id)
	load_dependencies()
	local store = module.get("store")
	if not store or not store.link then
		return false
	end
	return store.link.mark_completed(id) ~= nil
end

--- 重新打开任务（两端同时重新打开）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.reopen_link(id)
	load_dependencies()
	local store = module.get("store")
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
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.is_valid_transition(current_status, target_status)
end

--- 获取可用的状态流转列表
--- @param current_status string 当前状态
--- @return table 可用状态列表
function M.get_available_transitions(current_status)
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.get_available_transitions(current_status)
end

--- 判断状态是否可手动切换
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.is_user_switchable(status)
end

--- 获取下一个状态
--- @param current_status string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string 下一个状态
function M.get_next_status(current_status, include_completed)
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.get_next_status(current_status, include_completed)
end

--- 获取当前行的链接信息（纯数据查询）
--- @return table|nil
function M.get_current_link_info()
	load_dependencies()
	local status_mod = load_module("core.status")
	return status_mod.get_current_link_info()
end

---------------------------------------------------------------------
-- 事件系统API
---------------------------------------------------------------------
function M.notify_state_changed(ev)
	load_dependencies()
	local events = load_module("core.events")
	return events.on_state_changed(ev)
end

---------------------------------------------------------------------
-- 自动保存API
---------------------------------------------------------------------
function M.request_autosave(bufnr)
	load_dependencies()
	local autosave = load_module("core.autosave")
	return autosave.request_save(bufnr)
end

function M.flush_autosave(bufnr)
	load_dependencies()
	local autosave = load_module("core.autosave")
	return autosave.flush(bufnr)
end

-- 归档功能
function M.get_archivable_tasks(bufnr)
	load_dependencies()
	local archive = load_module("core.archive")
	return archive.get_archivable_tasks(bufnr)
end

function M.archive_completed_tasks(bufnr)
	load_dependencies()
	local archive = load_module("core.archive")
	return archive.archive_completed_tasks(bufnr)
end

function M.get_archive_stats(bufnr)
	load_dependencies()
	local archive = load_module("core.archive")
	return archive.get_archive_stats(bufnr)
end

return M
