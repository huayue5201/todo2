-- lua/todo2/link/init.lua
--- @module todo2.link
--- @brief 双向链接系统核心模块

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")
local link_highlight = require("todo2.task.highlight")
local status = require("todo2.status")

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
	local tags = config.get("tags")

	link_highlight.setup_tag_highlights(tags)
	link_highlight.setup_dynamic_status_highlights()
	link_highlight.setup_status_highlights()

	-- ⭐ 新增：设置完成状态高亮组（删除线）
	link_highlight.setup_completion_highlights()

	-- ⭐ 新增：设置隐藏相关高亮组
	link_highlight.setup_conceal_highlights()

	-- ⭐ 初始化状态高亮组
	if status and status.setup_highlights then
		status.setup_highlights()
	end

	return M
end

return M
