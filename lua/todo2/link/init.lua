-- lua/todo2/link/init.lua
--- @module todo2.link
--- @brief 双向链接系统核心模块，使用统一模块加载器

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 模块依赖声明
---------------------------------------------------------------------
M.dependencies = {
	"config",
	"status",
	"store",
	"ui",
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
-- 配置管理
---------------------------------------------------------------------
function M.setup()
	-- 加载依赖
	load_dependencies()

	-- 获取配置
	local config = module.get("config")
	local link_config = config.get_link()

	-- ⭐ 自动生成 TAG 高亮组
	local highlight = module.get("link.highlight")
	if link_config.render then
		if link_config.render.tags then
			highlight.setup_tag_highlights(link_config.render.tags)
		end
		highlight.setup_dynamic_status_highlights()
	end

	-- ⭐ 初始化状态高亮组
	local status_mod = module.get("status")
	status_mod.setup_highlights()

	-- ⭐ 插件启动时自动清理数据库
	local cleaner = module.get("link.cleaner")
	if cleaner and cleaner.cleanup_all_links then
		cleaner.cleanup_all_links()
	end

	return M
end

function M.get_jump_config()
	local config = module.get("config")
	return config.get_link_jump()
end

function M.get_preview_config()
	local config = module.get("config")
	return config.get_link_preview()
end

function M.get_render_config()
	local config = module.get("config")
	return config.get_link_render()
end

function M.get_config()
	local config = module.get("config")
	return config.get_link()
end

---------------------------------------------------------------------
-- 公开 API（使用统一的模块加载器）
---------------------------------------------------------------------

function M.create_link()
	load_dependencies()
	return module.get("link.creator").create_link()
end

function M.jump_to_todo()
	load_dependencies()
	return module.get("link.jumper").jump_to_todo()
end

function M.jump_to_code()
	load_dependencies()
	return module.get("link.jumper").jump_to_code()
end

function M.jump_dynamic()
	load_dependencies()
	return module.get("link.jumper").jump_dynamic()
end

function M.render_code_status(bufnr)
	load_dependencies()
	return module.get("link.renderer").render_code_status(bufnr)
end

function M.sync_code_links()
	load_dependencies()
	return module.get("link.syncer").sync_code_links()
end

function M.sync_todo_links()
	load_dependencies()
	return module.get("link.syncer").sync_todo_links()
end

function M.preview_todo()
	load_dependencies()
	return module.get("link.preview").preview_todo()
end

function M.preview_code()
	load_dependencies()
	return module.get("link.preview").preview_code()
end

function M.cleanup_all_links()
	load_dependencies()
	return module.get("link.cleaner").cleanup_all_links()
end

function M.cleanup_orphan_links_in_buffer()
	load_dependencies()
	return module.get("link.cleaner").cleanup_orphan_links_in_buffer()
end

function M.search_links_by_file(filepath)
	load_dependencies()
	return module.get("link.searcher").search_links_by_file(filepath)
end

function M.search_links_by_pattern(pattern)
	load_dependencies()
	return module.get("link.searcher").search_links_by_pattern(pattern)
end

function M.delete_code_link_by_id(id)
	load_dependencies()
	return module.get("link.deleter").delete_code_link_by_id(id)
end

function M.delete_store_links_by_id(id)
	load_dependencies()
	return module.get("link.deleter").delete_store_links_by_id(id)
end

function M.on_todo_deleted(id)
	load_dependencies()
	return module.get("link.deleter").on_todo_deleted(id)
end

function M.on_code_deleted(id, opts)
	load_dependencies()
	return module.get("link.deleter").on_code_deleted(id, opts)
end

function M.delete_code_link()
	load_dependencies()
	return module.get("link.deleter").delete_code_link()
end

---------------------------------------------------------------------
-- 工具函数（使用统一的模块加载器）
---------------------------------------------------------------------

function M.generate_id()
	load_dependencies()
	return module.get("link.utils").generate_id()
end

function M.find_task_insert_position(lines)
	load_dependencies()
	return module.get("link.utils").find_task_insert_position(lines)
end

function M.is_todo_floating_window(win_id)
	load_dependencies()
	return module.get("link.utils").is_todo_floating_window(win_id)
end

function M.insert_code_tag_above(bufnr, row, id, tag)
	load_dependencies()
	return module.get("link.utils").insert_code_tag_above(bufnr, row, id, tag)
end

function M.get_comment_prefix(bufnr)
	load_dependencies()
	return module.get("link.utils").get_comment_prefix(bufnr)
end

---------------------------------------------------------------------
-- 服务函数
---------------------------------------------------------------------
function M.create_code_link(bufnr, line, id, content)
	load_dependencies()
	return module.get("link.service").create_code_link(bufnr, line, id, content)
end

function M.create_todo_link(path, line, id, content)
	load_dependencies()
	return module.get("link.service").create_todo_link(path, line, id, content)
end

function M.insert_task_line(bufnr, lnum, options)
	load_dependencies()
	return module.get("link.service").insert_task_line(bufnr, lnum, options)
end

function M.ensure_task_id(bufnr, lnum, task)
	load_dependencies()
	return module.get("link.service").ensure_task_id(bufnr, lnum, task)
end

function M.insert_task_to_todo_file(todo_path, id, task_content)
	load_dependencies()
	return module.get("link.service").insert_task_to_todo_file(todo_path, id, task_content)
end

function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	load_dependencies()
	return module.get("link.service").create_child_task(parent_bufnr, parent_task, child_id, content)
end

---------------------------------------------------------------------
-- 子任务相关
---------------------------------------------------------------------
function M.create_child_from_code()
	load_dependencies()
	return module.get("link.child").create_child_from_code()
end

function M.on_cr_in_todo()
	load_dependencies()
	return module.get("link.child").on_cr_in_todo()
end

---------------------------------------------------------------------
-- 查看器相关
---------------------------------------------------------------------
function M.show_project_links_qf()
	load_dependencies()
	return module.get("link.viewer").show_project_links_qf()
end

function M.show_buffer_links_loclist()
	load_dependencies()
	return module.get("link.viewer").show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 返回模块
---------------------------------------------------------------------
return M
