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

-- 切换任务状态
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
	return load_module("parser").parse_tasks(lines)
end

---------------------------------------------------------------------
-- 事件系统API
---------------------------------------------------------------------
function M.notify_state_changed(ev)
	load_dependencies()
	return load_module("events").on_state_changed(ev)
end

-- 工具函数
function M.get_task_status(task)
	load_dependencies()
	return load_module("utils").get_task_status(task)
end

function M.get_task_text(task, max_len)
	load_dependencies()
	return load_module("utils").get_task_text(task, max_len)
end

function M.get_task_progress(task)
	load_dependencies()
	return load_module("utils").get_task_progress(task)
end

function M.parse_task_line(line)
	load_dependencies()
	return load_module("utils").parse_task_line(line)
end

function M.format_task_line(options)
	load_dependencies()
	return load_module("utils").format_task_line(options)
end

function M.ensure_task_id(bufnr, lnum, task)
	load_dependencies()
	return load_module("utils").ensure_task_id(bufnr, lnum, task)
end

function M.get_line_indent(bufnr, lnum)
	load_dependencies()
	return load_module("utils").get_line_indent(bufnr, lnum)
end

function M.get_task_at_line(bufnr, lnum)
	load_dependencies()
	return load_module("utils").get_task_at_line(bufnr, lnum)
end

function M.extract_tag_from_content(content)
	load_dependencies()
	return load_module("utils").extract_tag_from_content(content)
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
