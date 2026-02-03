-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（适配新版store）

local M = {}

local module = require("todo2.module")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 模块缓存
---------------------------------------------------------------------
local store, events

local function get_modules()
	if not store then
		store = module.get("store")
	end
	if not events then
		events = module.get("core.events")
	end
	return store, events
end

---------------------------------------------------------------------
-- 核心状态更新函数（适配新版store）
---------------------------------------------------------------------

--- 更新状态（适配新版store的双向同步）
--- @param id string 链接ID
--- @param new_status string 新状态
--- @param link_type string|nil 链接类型，nil表示双向同步
--- @param source string 事件来源
--- @return boolean 是否成功
function M.update_status(id, new_status, link_type, source)
	local store, events = get_modules()
	if not store then
		vim.notify("无法获取store模块", vim.log.levels.ERROR)
		return false
	end

	-- ⭐ 简化：新版store.update_status已支持双向同步，只需调用一次
	local success = store.update_status(id, new_status, link_type)

	if not success then
		return false
	end

	-- 清除缓存
	local cache = require("todo2.cache")
	if cache and cache.clear_on_status_change then
		cache.clear_on_status_change(id)
	end

	-- 触发事件
	if events then
		events.on_state_changed({
			source = source or "status_update",
			ids = { id },
			timestamp = os.time() * 1000,
		})
	end

	return true
end

---------------------------------------------------------------------
-- 状态流转验证（纯逻辑）
---------------------------------------------------------------------

function M.is_valid_transition(current_status, target_status)
	if current_status == target_status then
		return true
	end

	-- 完成状态可以切换到任何活跃状态
	if current_status == types.STATUS.COMPLETED then
		return target_status == types.STATUS.NORMAL
			or target_status == types.STATUS.URGENT
			or target_status == types.STATUS.WAITING
	end

	if target_status == types.STATUS.COMPLETED then
		return current_status == types.STATUS.NORMAL
			or current_status == types.STATUS.URGENT
			or current_status == types.STATUS.WAITING
	end

	return true
end

function M.get_available_transitions(current_status)
	local available = {}
	local active_states = {
		types.STATUS.NORMAL,
		types.STATUS.URGENT,
		types.STATUS.WAITING,
	}

	if current_status == types.STATUS.COMPLETED then
		for _, status in ipairs(active_states) do
			table.insert(available, status)
		end
	else
		for _, status in ipairs(active_states) do
			if status ~= current_status then
				table.insert(available, status)
			end
		end
	end

	return available
end

function M.is_user_switchable(status)
	return status ~= types.STATUS.COMPLETED
end

---------------------------------------------------------------------
-- 状态流转顺序（纯逻辑）
---------------------------------------------------------------------

function M.get_next_status(current_status, include_completed)
	if include_completed then
		local order = { "normal", "urgent", "waiting", "completed" }
		for i, status in ipairs(order) do
			if current_status == status then
				return order[i % #order + 1]
			end
		end
	else
		local order = { "normal", "urgent", "waiting" }
		for i, status in ipairs(order) do
			if current_status == status then
				return order[i % #order + 1]
			end
		end
	end

	return "normal"
end

---------------------------------------------------------------------
-- 链接信息获取（增强错误处理）
---------------------------------------------------------------------

--- 获取当前行的链接信息（不含UI逻辑）
--- @return table|nil
function M.get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	-- 解析链接ID
	local id, link_type, tag
	local tag, tag_id = line:match("(%u+):ref:(%w+)")
	if tag_id then
		id = tag_id
		link_type = "code"
	else
		id = line:match("{#(%w+)}")
		link_type = "todo"
	end

	if not id then
		return nil
	end

	-- 获取存储模块
	local store, _ = get_modules()
	if not store then
		vim.notify("无法获取store模块", vim.log.levels.WARN)
		return nil
	end

	local link
	if link_type == "todo" then
		link = store.get_todo_link(id)
	else
		link = store.get_code_link(id)
	end

	if not link then
		return nil
	end

	return {
		id = id,
		link_type = link_type,
		link = link,
		bufnr = bufnr,
		path = path,
		tag = tag,
	}
end

return M
