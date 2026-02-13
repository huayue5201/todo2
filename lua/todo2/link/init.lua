-- lua/todo2/link/init.lua
--- @module todo2.link
--- @brief 双向链接系统核心模块

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")

-- 子模块直接引入
local link_jumper = require("todo2.link.jumper")
local link_renderer = require("todo2.link.renderer")
local link_preview = require("todo2.link.preview")
local link_searcher = require("todo2.link.searcher")
local link_deleter = require("todo2.link.deleter")
local link_utils = require("todo2.link.utils")
local link_viewer = require("todo2.link.viewer")
local link_highlight = require("todo2.link.highlight")

-- 其他依赖模块
local status = require("todo2.status")
local store = require("todo2.store")
local ui = require("todo2.ui")

---------------------------------------------------------------------
-- 模块依赖声明（用于文档）
---------------------------------------------------------------------
M.dependencies = {
	"status",
	"store",
	"ui",
}

---------------------------------------------------------------------
-- 配置管理
---------------------------------------------------------------------
function M.setup()
	-- ⭐ 修改：直接使用新的配置模块
	local tags = config.get("tags")

	-- ⭐ 自动生成 TAG 高亮组
	if tags then
		link_highlight.setup_tag_highlights(tags)
	end
	link_highlight.setup_dynamic_status_highlights()
	link_highlight.setup_status_highlights()

	-- ⭐ 初始化状态高亮组
	if status and status.setup_highlights then
		status.setup_highlights()
	end

	return M
end

---------------------------------------------------------------------
-- 公开 API
---------------------------------------------------------------------

function M.jump_to_todo()
	return link_jumper.jump_to_todo()
end

function M.jump_to_code()
	return link_jumper.jump_to_code()
end

function M.jump_dynamic()
	return link_jumper.jump_dynamic()
end

function M.render_code_status(bufnr)
	return link_renderer.render_code_status(bufnr)
end

function M.preview_todo()
	return link_preview.preview_todo()
end

function M.preview_code()
	return link_preview.preview_code()
end

function M.search_links_by_file(filepath)
	return link_searcher.search_links_by_file(filepath)
end

function M.search_links_by_pattern(pattern)
	return link_searcher.search_links_by_pattern(pattern)
end

function M.delete_code_link_by_id(id)
	return link_deleter.delete_code_link_by_id(id)
end

function M.delete_store_links_by_id(id)
	return link_deleter.delete_store_links_by_id(id)
end

function M.on_todo_deleted(id)
	return link_deleter.on_todo_deleted(id)
end

function M.on_code_deleted(id, opts)
	return link_deleter.on_code_deleted(id, opts)
end

function M.delete_code_link()
	return link_deleter.delete_code_link()
end

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

function M.generate_id()
	return link_utils.generate_id()
end

function M.find_task_insert_position(lines)
	return link_utils.find_task_insert_position(lines)
end

function M.is_todo_floating_window(win_id)
	return link_utils.is_todo_floating_window(win_id)
end

function M.insert_code_tag_above(bufnr, row, id, tag)
	return link_utils.insert_code_tag_above(bufnr, row, id, tag)
end

function M.get_comment_prefix(bufnr)
	return link_utils.get_comment_prefix(bufnr)
end

---------------------------------------------------------------------
-- 查看器相关
---------------------------------------------------------------------
function M.show_project_links_qf()
	return link_viewer.show_project_links_qf()
end

function M.show_buffer_links_loclist()
	return link_viewer.show_buffer_links_loclist()
end

---------------------------------------------------------------------
-- 返回模块
---------------------------------------------------------------------
return M
