-- lua/todo2/link/init.lua
--- @module todo2.link
--- @brief 双向链接系统核心模块，使用统一模块加载器

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 新的配置模块
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- 模块依赖声明
---------------------------------------------------------------------
M.dependencies = {
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

	-- ⭐ 修改：直接使用新的配置模块
	local tags = config.get("tags")

	-- ⭐ 自动生成 TAG 高亮组
	local highlight = module.get("link.highlight")
	if tags then
		highlight.setup_tag_highlights(tags)
	end
	highlight.setup_dynamic_status_highlights()
	highlight.setup_status_highlights()

	-- ⭐ 初始化状态高亮组
	local status_mod = module.get("status")
	if status_mod and status_mod.setup_highlights then
		status_mod.setup_highlights()
	end

	return M
end

---------------------------------------------------------------------
-- ⭐ 移除旧的配置获取函数
-- 不再需要这些函数，因为所有模块都直接使用 config.get()
---------------------------------------------------------------------

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
