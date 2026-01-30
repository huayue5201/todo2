-- lua/todo2/store/init.lua
--- @module todo2.store

local M = {}

----------------------------------------------------------------------
-- 子模块加载（直接 require）
----------------------------------------------------------------------
local index = require("todo2.store.index")
local context = require("todo2.store.context")
local link = require("todo2.store.link")
local meta = require("todo2.store.meta")
local cleanup = require("todo2.store.cleanup")
local store = require("todo2.store.nvim_store")

----------------------------------------------------------------------
-- 保持外部 API 不变
----------------------------------------------------------------------

-- 路径规范化
function M._normalize_path(path)
	return index._normalize_path(path)
end

-- 上下文函数
function M.build_context(prev, curr, next)
	return context.build(prev, curr, next)
end

function M.context_match(old_ctx, new_ctx)
	return context.match(old_ctx, new_ctx)
end

-- 初始化
function M.init()
	return meta.init()
end

-- 模块初始化（统一的 setup 方法）
function M.setup()
	-- 初始化元数据
	M.init()

	-- 迁移状态字段（向后兼容）
	M.migrate_status_fields()

	return M
end

-- 链接操作
function M.add_todo_link(id, data)
	return link.add_todo(id, data)
end

function M.add_code_link(id, data)
	return link.add_code(id, data)
end

function M.get_todo_link(id, opts)
	return link.get_todo(id, opts)
end

function M.get_code_link(id, opts)
	return link.get_code(id, opts)
end

function M.delete_todo_link(id)
	return link.delete_todo(id)
end

function M.delete_code_link(id)
	return link.delete_code(id)
end

function M.get_all_todo_links()
	return link.get_all_todo()
end

function M.get_all_code_links()
	return link.get_all_code()
end

-- 索引操作
function M.find_todo_links_by_file(filepath)
	return index.find_todo_links_by_file(filepath)
end

function M.find_code_links_by_file(filepath)
	return index.find_code_links_by_file(filepath)
end

-- 清理操作
function M.cleanup_expired(days, opts)
	return cleanup.cleanup(days, opts)
end

function M.validate_all_links(opts)
	return cleanup.validate_all(opts)
end

----------------------------------------------------------------------
-- 新增状态管理API
----------------------------------------------------------------------

--- 更新链接状态
--- @param id string
--- @param status string
--- @param link_type string|nil
function M.update_status(id, status, link_type)
	return link.update_status(id, status, link_type)
end

--- 标记为完成
--- @param id string
--- @param link_type string|nil
function M.mark_completed(id, link_type)
	return link.mark_completed(id, link_type)
end

--- 标记为紧急
--- @param id string
--- @param link_type string|nil
function M.mark_urgent(id, link_type)
	return link.mark_urgent(id, link_type)
end

--- 标记为等待
--- @param id string
--- @param link_type string|nil
function M.mark_waiting(id, link_type)
	return link.mark_waiting(id, link_type)
end

--- 标记为正常
--- @param id string
--- @param link_type string|nil
function M.mark_normal(id, link_type)
	return link.mark_normal(id, link_type)
end

--- 恢复到上一次状态
--- @param id string
--- @param link_type string|nil
function M.restore_previous_status(id, link_type)
	return link.restore_previous_status(id, link_type)
end

--- 根据状态筛选链接
--- @param status string
--- @param link_type string|nil
--- @return table
function M.filter_by_status(status, link_type)
	return link.filter_by_status(status, link_type)
end

--- 获取状态统计
--- @param link_type string|nil
--- @return table
function M.get_status_stats(link_type)
	-- 现在调用link.lua中的统一实现
	return link.get_status_stats(link_type)
end

--- 清理已完成的链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	return cleanup.cleanup_completed(days)
end

--- 迁移状态字段（向后兼容）
function M.migrate_status_fields()
	return link.migrate_status_fields()
end

--- 获取数据完整性报告
--- @return table
function M.get_integrity_report()
	return link.get_integrity_report()
end

--- 修复数据完整性问题
--- @return table
function M.fix_integrity_issues()
	return link.fix_integrity_issues()
end

----------------------------------------------------------------------
-- 高级功能
----------------------------------------------------------------------

--- 获取存储统计
--- @return table
function M.get_stats()
	local link_stats = link.get_all_todo()
	local code_stats = link.get_all_code()
	local meta_stats = meta.get_stats()

	return {
		todo_links = #link_stats,
		code_links = #code_stats,
		total_links = meta_stats.total_links,
		last_sync = meta_stats.last_sync,
		project_root = meta_stats.project_root,
		version = meta_stats.version,
	}
end

--- 导出所有数据（用于备份）
--- @return table
function M.export()
	local data = {
		meta = meta.get(),
		todo_links = link.get_all_todo(),
		code_links = link.get_all_code(),
		export_time = os.time(),
		export_version = "1.0",
	}

	return data
end

--- 导入数据（从备份恢复）
--- @param data table
--- @param opts table|nil
function M.import(data, opts)
	opts = opts or {}
	local overwrite = opts.overwrite or false

	if data.export_version ~= "1.0" then
		error("不支持的导出版本: " .. (data.export_version or "unknown"))
	end

	if overwrite then
		-- 清除现有数据
		local todo_keys = store.get_namespace_keys("todo.links.todo")
		local code_keys = store.get_namespace_keys("todo.links.code")

		for _, key in ipairs(todo_keys) do
			store.delete_key(key)
		end

		for _, key in ipairs(code_keys) do
			store.delete_key(key)
		end
	end

	-- 导入元数据
	if data.meta then
		store.set_key("todo.meta", data.meta)
	end

	-- 导入链接
	if data.todo_links then
		for id, link_data in pairs(data.todo_links) do
			store.set_key("todo.links.todo." .. id, link_data)
		end
	end

	if data.code_links then
		for id, link_data in pairs(data.code_links) do
			store.set_key("todo.links.code." .. id, link_data)
		end
	end

	return true
end

--- 修复链接（新增功能）
--- @param opts table|nil
--- @return table
function M.repair_links(opts)
	return cleanup.repair_links(opts)
end

--- 重建索引（新增功能）
--- @param link_type string
function M.rebuild_index(link_type)
	return index.rebuild_index(link_type)
end

--- 获取项目根目录（新增功能）
--- @return string
function M.get_project_root()
	return meta.get_project_root()
end

-- API包装器，提供更好的错误处理
local function wrap_api(fn)
	return function(...)
		local ok, result = pcall(fn, ...)
		if not ok then
			vim.notify(string.format("todo2.store error: %s", result), vim.log.levels.ERROR)
			return nil
		end
		return result
	end
end

-- 包装所有公共API（以下划线开头的除外）
for name, fn in pairs(M) do
	if type(fn) == "function" and not name:match("^_") then
		M[name] = wrap_api(fn)
	end
end

return M
