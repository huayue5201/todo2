-- lua/todo2/core/init.lua
--- @module todo2.core
--- @brief 精简版核心模块入口

local M = {}

---------------------------------------------------------------------
-- 模块懒加载
---------------------------------------------------------------------
local module = require("todo2.module")

-- 按需加载模块
local function load_module(name)
	return module.get("core." .. name)
end

---------------------------------------------------------------------
-- ⭐ 精简API：只暴露核心业务功能
---------------------------------------------------------------------

-- 解析文件（直接转发）
function M.parse_file(path)
	return load_module("parser").parse_file(path)
end

-- 切换任务状态
function M.toggle_line(bufnr, lnum, opts)
	return load_module("state_manager").toggle_line(bufnr, lnum, opts)
end

-- 刷新任务树
function M.refresh(bufnr)
	local main_module = module.get("main")
	return load_module("state_manager").refresh(bufnr, main_module)
end

-- 计算统计
function M.calculate_all_stats(tasks)
	return load_module("stats").calculate_all_stats(tasks)
end

function M.summarize(lines, path)
	return load_module("stats").summarize(lines, path)
end

-- 清理缓存
function M.clear_cache()
	load_module("parser").clear_cache()
end

---------------------------------------------------------------------
-- ⭐ 事件系统API（新增）
---------------------------------------------------------------------
function M.notify_state_changed(ev)
	return load_module("events").on_state_changed(ev)
end

return M
