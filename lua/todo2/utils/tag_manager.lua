-- lua/todo2/utils/tag_manager.lua
-- 适配新格式：使用内部格式获取标签

local M = {}

local config = require("todo2.config")
local core = require("todo2.store.link.core")

function M.get_configured_tags()
	return config.get("tags") or {}
end

--- 获取标签 - 直接从内部格式读取
function M.get_tag(id, opts)
	opts = opts or {}

	local task = core.get_task(id)
	if not task then
		return "TODO"
	end

	-- 返回第一个标签作为主标签（保持兼容）
	return task.core.tags[1] or "TODO"
end

--- 获取所有标签（新功能，但保留旧接口）
function M.get_all_tags(id)
	local task = core.get_task(id)
	if not task then
		return { "TODO" }
	end
	return task.core.tags or { "TODO" }
end

--- 设置标签（新功能，支持多标签）
function M.set_tags(id, tags)
	if type(tags) == "string" then
		tags = { tags }
	end

	local task = core.get_task(id)
	if not task then
		return false
	end

	task.core.tags = tags
	task.timestamps.updated = os.time()

	return core.save_task(id, task)
end

--- 添加标签
function M.add_tag(id, tag)
	local task = core.get_task(id)
	if not task then
		return false
	end

	if not task.core.tags then
		task.core.tags = {}
	end

	-- 避免重复
	for _, t in ipairs(task.core.tags) do
		if t == tag then
			return true
		end
	end

	table.insert(task.core.tags, tag)
	task.timestamps.updated = os.time()

	return core.save_task(id, task)
end

--- 移除标签
function M.remove_tag(id, tag)
	local task = core.get_task(id)
	if not task or not task.core.tags then
		return false
	end

	local new_tags = {}
	for _, t in ipairs(task.core.tags) do
		if t ~= tag then
			table.insert(new_tags, t)
		end
	end

	-- 确保至少有一个标签
	if #new_tags == 0 then
		new_tags = { "TODO" }
	end

	task.core.tags = new_tags
	task.timestamps.updated = os.time()

	return core.save_task(id, task)
end

-- 保留所有原有函数名，内部调用新实现
function M._get_storage_tag(id)
	return M.get_tag(id)
end

function M._get_realtime_tag(id)
	-- 简化：直接返回存储的标签
	return M.get_tag(id)
end

function M._fix_tag_inconsistency(id, old_tag, new_tag)
	if old_tag ~= new_tag then
		vim.notify(
			string.format("标签不一致: %s → %s (ID: %s)", old_tag, new_tag, id:sub(1, 6)),
			vim.log.levels.DEBUG
		)

		-- 如果新标签有效，更新存储
		if new_tag and new_tag ~= "TODO" then
			M.set_tags(id, { new_tag })
		end
	end
end

function M._log_tag_inconsistency(id, storage_tag, realtime_tag)
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

--- 兼容旧接口：检查标签是否存在
function M.has_tag(id, tag)
	local tags = M.get_all_tags(id)
	for _, t in ipairs(tags) do
		if t == tag then
			return true
		end
	end
	return false
end

--- 兼容旧接口：获取标签颜色等元数据
function M.get_tag_metadata(tag)
	local tags_config = M.get_configured_tags()
	return tags_config[tag] or {}
end

return M
