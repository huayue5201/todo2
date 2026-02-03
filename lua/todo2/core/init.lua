-- lua/todo2/core/init.lua
--- @module todo2.core
--- @brief 精简版核心模块入口

local M = {}

---------------------------------------------------------------------
-- 模块懒加载
---------------------------------------------------------------------
local module = require("todo2.module")

-- 按需加载子模块
local function load_module(name)
	return module.get("core." .. name)
end

---------------------------------------------------------------------
-- 模块依赖声明
---------------------------------------------------------------------
M.dependencies = {
	"config",
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
-- 精简API：只暴露核心业务功能
---------------------------------------------------------------------

-- 解析文件
function M.parse_file(path)
	load_dependencies()
	return load_module("parser").parse_file(path)
end

-- 切换任务状态（核心功能，保留）
function M.toggle_line(bufnr, lnum, opts)
	load_dependencies()
	return load_module("state_manager").toggle_line(bufnr, lnum, opts)
end

-- 刷新任务树
function M.refresh(bufnr)
	load_dependencies()
	local main_module = module.get("main")
	return load_module("state_manager").refresh(bufnr, main_module)
end

-- 计算统计
function M.calculate_all_stats(tasks)
	load_dependencies()
	return load_module("stats").calculate_all_stats(tasks)
end

function M.summarize(lines, path)
	load_dependencies()
	return load_module("stats").summarize(lines, path)
end

-- 清理缓存
function M.clear_cache()
	load_dependencies()
	load_module("parser").clear_cache()
end

-- 解析任务
function M.parse_tasks(lines)
	load_dependencies()
	-- 直接调用 parser.parse_tasks，它现在返回 tasks
	return load_module("parser").parse_tasks(lines)
end

---------------------------------------------------------------------
-- 核心状态管理API
---------------------------------------------------------------------

--- 更新任务状态（核心函数，不包含UI逻辑）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param link_type string 链接类型
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_status(id, new_status, link_type, source)
	load_dependencies()
	return load_module("status").update_status(id, new_status, link_type, source)
end

--- 验证状态流转
--- @param current_status string 当前状态
--- @param target_status string 目标状态
--- @return boolean 是否可以切换
function M.is_valid_transition(current_status, target_status)
	load_dependencies()
	return load_module("status").is_valid_transition(current_status, target_status)
end

--- 获取可用的状态流转列表
--- @param current_status string 当前状态
--- @return table 可用状态列表
function M.get_available_transitions(current_status)
	load_dependencies()
	return load_module("status").get_available_transitions(current_status)
end

--- 判断状态是否可手动切换
--- @param status string 状态
--- @return boolean
function M.is_user_switchable(status)
	load_dependencies()
	return load_module("status").is_user_switchable(status)
end

--- 获取下一个状态
--- @param current_status string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string 下一个状态
function M.get_next_status(current_status, include_completed)
	load_dependencies()
	return load_module("status").get_next_status(current_status, include_completed)
end

--- 获取当前行的链接信息（纯数据查询）
--- @return table|nil
function M.get_current_link_info()
	load_dependencies()
	return load_module("status").get_current_link_info()
end

---------------------------------------------------------------------
-- 事件系统API
---------------------------------------------------------------------
function M.notify_state_changed(ev)
	load_dependencies()
	return load_module("events").on_state_changed(ev)
end

---------------------------------------------------------------------
-- 自动保存API
---------------------------------------------------------------------
function M.request_autosave(bufnr)
	load_dependencies()
	return load_module("autosave").request_save(bufnr)
end

function M.flush_autosave(bufnr)
	load_dependencies()
	return load_module("autosave").flush(bufnr)
end

return M
