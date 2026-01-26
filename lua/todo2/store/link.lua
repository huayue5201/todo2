-- lua/todo2/store/link.lua
--- @module todo2.store.link

local store = require("todo2.store.nvim_store")
local meta = require("todo2.store.meta")
local index = require("todo2.store.index")
local context = require("todo2.store.context")
local types = require("todo2.store.types")

local M = {}

----------------------------------------------------------------------
-- 链接操作
----------------------------------------------------------------------
--- 添加TODO链接
--- @param id string
--- @param data table
--- @return boolean
function M.add_todo(id, data)
	local now = os.time()

	local link = {
		id = id,
		type = types.LINK_TYPES.TODO_TO_CODE,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
		context = data.context,
	}

	store.set_key("todo.links.todo." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_todo", link.path, id)
	meta.increment_links(1)

	return true
end

--- 添加代码链接
--- @param id string
--- @param data table
--- @return boolean
function M.add_code(id, data)
	local now = os.time()

	local link = {
		id = id,
		type = types.LINK_TYPES.CODE_TO_TODO,
		path = index._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
		context = data.context,
	}

	store.set_key("todo.links.code." .. id, link)
	index._add_id_to_file_index("todo.index.file_to_code", link.path, id)
	meta.increment_links(1)

	return true
end

--- 获取TODO链接
--- @param id string
--- @param opts table|nil
--- @return TodoLink|nil
function M.get_todo(id, opts)
	opts = opts or {}
	local link = store.get_key("todo.links.todo." .. id)

	if link and opts.force_relocate then
		link = M._relocate_link_if_needed(link, opts)
	end

	return link
end

--- 获取代码链接
--- @param id string
--- @param opts table|nil
--- @return TodoLink|nil
function M.get_code(id, opts)
	opts = opts or {}
	local link = store.get_key("todo.links.code." .. id)

	if link and opts.force_relocate then
		link = M._relocate_link_if_needed(link, opts)
	end

	return link
end

--- 删除TODO链接
--- @param id string
function M.delete_todo(id)
	local link = M.get_todo(id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
		store.delete_key("todo.links.todo." .. id)
		meta.decrement_links(1)
	end
end

--- 删除代码链接
--- @param id string
function M.delete_code(id)
	local link = M.get_code(id)
	if link then
		index._remove_id_from_file_index("todo.index.file_to_code", link.path, id)
		store.delete_key("todo.links.code." .. id)
		meta.decrement_links(1)
	end
end

--- 更新链接
--- @param id string
--- @param updates table
--- @param link_type string
function M.update(id, updates, link_type)
	local key_prefix = link_type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo" or "todo.links.code"
	local key = key_prefix .. "." .. id
	local link = store.get_key(key)

	if link then
		for k, v in pairs(updates) do
			link[k] = v
		end
		link.updated_at = os.time()
		store.set_key(key, link)
	end
end

----------------------------------------------------------------------
-- 批量操作
----------------------------------------------------------------------
--- 获取所有TODO链接
--- @return table<string, TodoLink>
function M.get_all_todo()
	local ids = store.get_namespace_keys("todo.links.todo")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.todo." .. id)
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接
--- @return table<string, TodoLink>
function M.get_all_code()
	local ids = store.get_namespace_keys("todo.links.code")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.code." .. id)
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

----------------------------------------------------------------------
-- 链接重定位
----------------------------------------------------------------------
--- 重新定位链接（文件移动时使用）
--- @param link TodoLink
--- @param opts table
--- @return TodoLink
function M._relocate_link_if_needed(link, opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	if not link or not link.path then
		return link
	end

	local norm = index._normalize_path(link.path)
	if vim.fn.filereadable(norm) == 1 then
		return link
	end

	local project_root = meta.get_project_root()
	local filename = vim.fn.fnamemodify(link.path, ":t")
	if filename == "" then
		return link
	end

	local pattern = project_root .. "/**/" .. filename
	local matches = vim.fn.glob(pattern, false, true)

	if #matches == 0 then
		if verbose then
			vim.notify("todo2: 无法重新定位 " .. link.id, vim.log.levels.DEBUG)
		end
		return link
	end

	-- 更新链接路径
	local old_path = link.path
	local new_path = matches[1]

	link.path = index._normalize_path(new_path)
	link.updated_at = os.time()

	-- 更新存储
	local key = link.type == types.LINK_TYPES.CODE_TO_TODO and "todo.links.code." .. link.id
		or "todo.links.todo." .. link.id

	store.set_key(key, link)

	-- 更新索引
	if link.type == types.LINK_TYPES.CODE_TO_TODO then
		index._remove_id_from_file_index("todo.index.file_to_code", old_path, link.id)
		index._add_id_to_file_index("todo.index.file_to_code", new_path, link.id)
	else
		index._remove_id_from_file_index("todo.index.file_to_todo", old_path, link.id)
		index._add_id_to_file_index("todo.index.file_to_todo", new_path, link.id)
	end

	return link
end

return M
