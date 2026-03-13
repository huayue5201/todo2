-- lua/todo2/utils/tag_manager.lua
-- 保留所有API，内部实现简化

local M = {}

local config = require("todo2.config")
local link_mod = require("todo2.store.link")

function M.get_configured_tags()
	return config.get("tags") or {}
end

--- 获取标签 - 直接从存储读取
function M.get_tag(id, opts)
	opts = opts or {}

	-- 直接从存储获取（唯一真相）
	local code_link = link_mod.get_code(id)
	if code_link and code_link.tag and code_link.tag ~= "TODO" then
		return code_link.tag
	end

	local todo_link = link_mod.get_todo(id)
	if todo_link and todo_link.tag and todo_link.tag ~= "TODO" then
		return todo_link.tag
	end

	return "TODO"
end

-- 保留所有原有函数，但内部都调用 get_tag
function M._get_storage_tag(id)
	return M.get_tag(id)
end

function M._get_realtime_tag(id)
	-- 简化：直接返回存储的标签（不再实时解析）
	return M.get_tag(id)
end

function M._fix_tag_inconsistency(id, old_tag, new_tag)
	-- 简化：不再修复，直接记录
	if old_tag ~= new_tag then
		vim.notify(
			string.format("标签不一致: %s → %s (ID: %s)", old_tag, new_tag, id:sub(1, 6)),
			vim.log.levels.DEBUG
		)
	end
end

function M._log_tag_inconsistency(id, storage_tag, realtime_tag)
	-- 保留日志功能
	vim.notify(
		string.format("标签不一致: 存储=%s, 文件=%s (ID: %s)", storage_tag, realtime_tag, id:sub(1, 6)),
		vim.log.levels.DEBUG
	)
end

function M.get_tag_for_render(id)
	return M.get_tag(id)
end

function M.get_tag_for_user_action(id)
	return M.get_tag(id)
end

return M
