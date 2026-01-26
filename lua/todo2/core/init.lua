-- lua/todo2/core/init.lua
--- @module todo2.core

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 模块懒加载（使用模块管理器）
---------------------------------------------------------------------
local modules = {
	parser = nil,
	stats = nil,
	sync = nil,
	toggle = nil,
}

local function get_module(name)
	if not modules[name] then
		modules[name] = module.get("core." .. name)
	end
	return modules[name]
end

---------------------------------------------------------------------
-- ⭐ 新 parser 架构：只暴露 parse_file
---------------------------------------------------------------------
function M.parse_file(path)
	return get_module("parser").parse_file(path)
end

---------------------------------------------------------------------
-- 统计模块
---------------------------------------------------------------------
function M.calculate_all_stats(tasks)
	return get_module("stats").calculate_all_stats(tasks)
end

function M.summarize(lines, path)
	return get_module("stats").summarize(lines, path)
end

---------------------------------------------------------------------
-- 同步模块
---------------------------------------------------------------------
function M.sync_parent_child_state(tasks, bufnr)
	return get_module("sync").sync_parent_child_state(tasks, bufnr)
end

function M.refresh(bufnr)
	-- 需要传递当前 core 模块给 sync.refresh（用于渲染）
	local main_module = module.get("main")
	return get_module("sync").refresh(bufnr, main_module)
end

---------------------------------------------------------------------
-- 切换模块
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}
	local success, result = get_module("toggle").toggle_line(bufnr, lnum)

	-- 默认写盘（可通过 opts.skip_write 禁用）
	if success and not opts.skip_write then
		-- 使用 autosave 模块进行写盘
		local autosave = module.get("core.autosave")
		autosave.request_save(bufnr)
	end

	return success, result
end

---------------------------------------------------------------------
-- 工具函数（从 parser 导出）
---------------------------------------------------------------------
function M.get_indent(line)
	return get_module("parser").get_indent(line)
end

function M.is_task_line(line)
	return get_module("parser").is_task_line(line)
end

function M.parse_task_line(line)
	return get_module("parser").parse_task_line(line)
end

---------------------------------------------------------------------
-- 缓存清理
---------------------------------------------------------------------
function M.clear_cache()
	if modules.parser then
		modules.parser.clear_cache()
	end
	modules = {
		parser = nil,
		stats = nil,
		sync = nil,
		toggle = nil,
	}
end

return M
