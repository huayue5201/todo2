-- lua/todo2/store.lua
--- @module todo2.store
--- @brief 基于 nvim-store3 的双链存储层
---
--- 设计目标：
--- 1. 作为「单一真相源」，所有代码↔TODO 链接都以此为准
--- 2. 提供稳定的增删改查 API，供 link / manager / ui 等模块使用
--- 3. 支持路径规范化、自动重新定位（auto_relocate）、索引重建与验证
--- 4. 所有对外函数都带有清晰的 LuaDoc 注释，便于未来维护与扩展

local M = {}

----------------------------------------------------------------------
-- 内部依赖：懒加载 nvim-store3
----------------------------------------------------------------------

--- @class Todo2Store
--- @field get fun(self, key: string): any
--- @field set fun(self, key: string, value: any)
--- @field del fun(self, key: string)
--- @field namespace_keys fun(self, ns: string): string[]
--- @field on fun(self, event: string, cb: fun(ev: table))

--- @type Todo2Store|nil
local nvim_store

--- 获取项目级 store 实例（懒加载）
--- @return Todo2Store
local function get_store()
	if not nvim_store then
		nvim_store = require("nvim-store3").project({
			auto_encode = true,
			storage = {
				backend = "json",
				flush_delay = 1000,
			},
			plugins = {
				basic_cache = {
					enabled = true,
					default_ttl = 300,
				},
			},
		})
	end
	return nvim_store
end

-- 可选：监听 set 事件（目前预留扩展点）
get_store():on("set", function(ev)
	if ev.key:match("^todo%.links%.") then
		-- 这里可以添加调试日志、统计等
	end
end)

----------------------------------------------------------------------
-- 常量与内部工具
----------------------------------------------------------------------

--- 链接类型枚举
local LINK_TYPES = {
	--- 代码 → TODO（代码中有 TODO:ref:id，指向 TODO 文件中的 {#id}）
	CODE_TO_TODO = "code_to_todo",
	--- TODO → 代码（TODO 文件中的 {#id}，指向代码中的 TODO:ref:id）
	TODO_TO_CODE = "todo_to_code",
}

--- 归一化路径：统一为绝对路径，避免相对路径 / 大小写差异导致索引不一致
--- @param path string
--- @return string
function M._normalize_path(path)
	if not path or path == "" then
		return ""
	end
	-- 使用 Neovim 提供的路径归一化能力
	return vim.fn.fnamemodify(path, ":p")
end

--- 获取当前项目根目录（用于自动重新定位）
--- @return string
local function get_project_root()
	local store = get_store()
	local meta = store:get("todo.meta") or {}
	if meta.project_root and meta.project_root ~= "" then
		return meta.project_root
	end
	return vim.fn.getcwd()
end

----------------------------------------------------------------------
-- 初始化与扩展
----------------------------------------------------------------------

--- 初始化存储模块：创建基础元数据、预留扩展点
--- @return boolean success
function M.init()
	local store = get_store()

	-- 初始化元数据
	local meta = store:get("todo.meta") or {}
	if not meta.initialized then
		meta = {
			initialized = true,
			version = "2.0",
			created_at = os.time(),
			last_sync = os.time(),
			total_links = 0,
			project_root = vim.fn.getcwd(),
		}
		store:set("todo.meta", meta)
	end

	-- 预留扩展点
	M._setup_extensions()

	return true
end

--- 内部扩展初始化（目前预留，未来可挂插件）
function M._setup_extensions()
	-- local store = get_store()
	-- 例如：require("nvim-store3").register_plugin("todo_links", "todo2.store.extensions")
end

----------------------------------------------------------------------
-- 链接结构说明
--
-- 每个链接对象结构：
-- {
--   id         = "a1b2c3",
--   type       = "code_to_todo" | "todo_to_code",
--   path       = "/abs/path/to/file",
--   line       = 42,
--   content    = "原始行内容（可选）",
--   created_at = 1234567890,
--   updated_at = 1234567890,
--   active     = true,
-- }
--
-- 存储 key 约定：
--   todo.links.code.<id>  -- 代码 → TODO
--   todo.links.todo.<id>  -- TODO → 代码
--
-- 文件索引：
--   todo.index.file_to_code.<normalized_path> = { id1, id2, ... }
--   todo.index.file_to_todo.<normalized_path> = { id1, id2, ... }
----------------------------------------------------------------------

----------------------------------------------------------------------
-- 内部工具：索引维护
----------------------------------------------------------------------

--- 将 id 添加到文件索引中
--- @param index_ns "todo.index.file_to_code"|"todo.index.file_to_todo"
--- @param filepath string
--- @param id string
local function add_id_to_file_index(index_ns, filepath, id)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store:get(key) or {}

	-- 避免重复
	for _, existing in ipairs(list) do
		if existing == id then
			return
		end
	end

	table.insert(list, id)
	store:set(key, list)
end

--- 从文件索引中移除 id
--- @param index_ns "todo.index.file_to_code"|"todo.index.file_to_todo"
--- @param filepath string
--- @param id string
local function remove_id_from_file_index(index_ns, filepath, id)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store:get(key)
	if not list then
		return
	end

	local new_list = {}
	for _, existing in ipairs(list) do
		if existing ~= id then
			table.insert(new_list, existing)
		end
	end

	store:set(key, new_list)
end

----------------------------------------------------------------------
-- 自动重新定位逻辑（auto_relocate）
----------------------------------------------------------------------

--- 尝试重新定位一个链接的路径（文件被移动/重命名时）
--- 策略：基于文件名在项目根目录下搜索同名文件
---
--- @param link table 链接对象
--- @param opts table|nil { verbose?: boolean }
--- @return table link 可能已更新后的链接对象
local function relocate_link_if_needed(link, opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	if not link or not link.path then
		return link
	end

	local norm = M._normalize_path(link.path)
	if vim.fn.filereadable(norm) == 1 then
		-- 文件仍然存在，无需重新定位
		return link
	end

	-- 文件不存在，尝试在项目中搜索同名文件
	local project_root = get_project_root()
	local filename = vim.fn.fnamemodify(link.path, ":t")

	if filename == "" then
		return link
	end

	local pattern = project_root .. "/**/" .. filename
	local matches = vim.fn.glob(pattern, false, true)

	if #matches == 0 then
		if verbose then
			vim.notify(
				string.format("todo2: 无法重新定位链接 %s（原路径：%s）", link.id or "?", link.path),
				vim.log.levels.DEBUG
			)
		end
		return link
	end

	-- 简单策略：取第一个匹配
	local new_path = matches[1]
	link.path = M._normalize_path(new_path)
	link.updated_at = os.time()

	-- 写回 store
	local store = get_store()
	if link.type == LINK_TYPES.CODE_TO_TODO then
		store:set("todo.links.code." .. link.id, link)
	elseif link.type == LINK_TYPES.TODO_TO_CODE then
		store:set("todo.links.todo." .. link.id, link)
	end

	if verbose then
		vim.notify(
			string.format("todo2: 链接 %s 已重新定位到 %s", link.id or "?", link.path),
			vim.log.levels.DEBUG
		)
	end

	return link
end

----------------------------------------------------------------------
-- 对外 API：添加链接
----------------------------------------------------------------------

--- 添加 TODO 链接（TODO 文件中的 {#id} → 代码）
---
--- @param id string 唯一 ID
--- @param data table { path: string, line: integer, content?: string, created_at?: integer }
--- @return boolean success
function M.add_todo_link(id, data)
	local store = get_store()
	local now = os.time()

	local link = {
		id = id,
		type = LINK_TYPES.TODO_TO_CODE, -- ✅ TODO → 代码
		path = M._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
	}

	local key = string.format("todo.links.todo.%s", id)
	store:set(key, link)

	-- 更新文件索引
	add_id_to_file_index("todo.index.file_to_todo", link.path, id)

	-- 更新元数据
	local meta = store:get("todo.meta") or {}
	meta.total_links = (meta.total_links or 0) + 1
	meta.last_sync = now
	store:set("todo.meta", meta)

	return true
end

--- 添加代码链接（代码中的 TODO:ref:id → TODO）
---
--- @param id string 唯一 ID
--- @param data table { path: string, line: integer, content?: string, created_at?: integer }
--- @return boolean success
function M.add_code_link(id, data)
	local store = get_store()
	local now = os.time()

	local link = {
		id = id,
		type = LINK_TYPES.CODE_TO_TODO, -- ✅ 代码 → TODO
		path = M._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
	}

	local key = string.format("todo.links.code.%s", id)
	store:set(key, link)

	-- 更新文件索引
	add_id_to_file_index("todo.index.file_to_code", link.path, id)

	-- 元数据这里可以选择是否计数（与 add_todo_link 一致）
	local meta = store:get("todo.meta") or {}
	meta.total_links = (meta.total_links or 0) + 1
	meta.last_sync = now
	store:set("todo.meta", meta)

	return true
end

----------------------------------------------------------------------
-- 对外 API：获取单个链接
----------------------------------------------------------------------

--- 获取 TODO 链接（TODO → 代码）
---
--- @param id string
--- @param opts table|nil { force_relocate?: boolean, verbose?: boolean }
--- @return table|nil
function M.get_todo_link(id, opts)
	local store = get_store()
	local key = string.format("todo.links.todo.%s", id)
	local link = store:get(key)
	if not link then
		return nil
	end

	if opts and opts.force_relocate then
		link = relocate_link_if_needed(link, opts)
	end

	return link
end

--- 获取代码链接（代码 → TODO）
---
--- @param id string
--- @param opts table|nil { force_relocate?: boolean, verbose?: boolean }
--- @return table|nil
function M.get_code_link(id, opts)
	local store = get_store()
	local key = string.format("todo.links.code.%s", id)
	local link = store:get(key)
	if not link then
		return nil
	end

	if opts and opts.force_relocate then
		link = relocate_link_if_needed(link, opts)
	end

	return link
end

----------------------------------------------------------------------
-- 对外 API：批量查询
----------------------------------------------------------------------

--- 获取所有 TODO 链接（TODO → 代码）
--- @return table<string, table> 映射 id → link
function M.get_all_todo_links()
	local store = get_store()
	local ids = store:namespace_keys("todo.links.todo")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store:get("todo.links.todo." .. id)
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

--- 获取所有代码链接（代码 → TODO）
--- @return table<string, table> 映射 id → link
function M.get_all_code_links()
	local store = get_store()
	local ids = store:namespace_keys("todo.links.code")
	local result = {}

	for _, id in ipairs(ids) do
		local link = store:get("todo.links.code." .. id)
		if link and link.active ~= false then
			result[id] = link
		end
	end

	return result
end

----------------------------------------------------------------------
-- 对外 API：按文件查询
----------------------------------------------------------------------

--- 查找某个文件中的 TODO 链接（TODO → 代码）
---
--- @param filepath string
--- @return table[] { id: string, path: string, line: integer, content: string }
function M.find_todo_links_by_file(filepath)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local key = string.format("todo.index.file_to_todo.%s", norm)
	local ids = store:get(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = M.get_todo_link(id)
		if link then
			table.insert(results, {
				id = id,
				path = link.path,
				line = link.line,
				content = link.content,
			})
		end
	end

	return results
end

--- 查找某个文件中的代码链接（代码 → TODO）
---
--- @param filepath string
--- @return table[] { id: string, path: string, line: integer, content: string }
function M.find_code_links_by_file(filepath)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local key = string.format("todo.index.file_to_code.%s", norm)
	local ids = store:get(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = M.get_code_link(id)
		if link then
			table.insert(results, {
				id = id,
				path = link.path,
				line = link.line,
				content = link.content,
			})
		end
	end

	return results
end

----------------------------------------------------------------------
-- 对外 API：删除链接
----------------------------------------------------------------------

--- 删除链接（通用入口）
---
--- @param id string
--- @param kind "code"|"todo"
function M.delete_link(id, kind)
	if kind == "code" then
		return M.delete_code_link(id)
	elseif kind == "todo" then
		return M.delete_todo_link(id)
	end
end

--- 删除 TODO 链接（TODO → 代码）
---
--- @param id string
function M.delete_todo_link(id)
	local store = get_store()
	local key = string.format("todo.links.todo.%s", id)
	local link = store:get(key)
	if not link then
		return
	end

	-- 从文件索引中移除
	remove_id_from_file_index("todo.index.file_to_todo", link.path, id)

	-- 删除链接本身
	store:del(key)
end

--- 删除代码链接（代码 → TODO）
---
--- @param id string
function M.delete_code_link(id)
	local store = get_store()
	local key = string.format("todo.links.code.%s", id)
	local link = store:get(key)
	if not link then
		return
	end

	-- 从文件索引中移除
	remove_id_from_file_index("todo.index.file_to_code", link.path, id)

	-- 删除链接本身
	store:del(key)
end

----------------------------------------------------------------------
-- 对外 API：清理过期数据
----------------------------------------------------------------------

--- 清理过期数据（简单策略：按 created_at 距今天数）
---
--- @param days integer 多少天以前的数据视为过期
--- @return integer cleaned 清理的条数
function M.cleanup(days)
	local store = get_store()
	local now = os.time()
	local threshold = now - days * 24 * 60 * 60
	local cleaned = 0

	local all_code = M.get_all_code_links()
	for id, link in pairs(all_code) do
		if (link.created_at or 0) < threshold then
			M.delete_code_link(id)
			cleaned = cleaned + 1
		end
	end

	local all_todo = M.get_all_todo_links()
	for id, link in pairs(all_todo) do
		if (link.created_at or 0) < threshold then
			M.delete_todo_link(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

----------------------------------------------------------------------
-- 对外 API：验证所有链接
----------------------------------------------------------------------

--- 验证所有链接的完整性与文件存在性
---
--- @param opts table|nil { verbose?: boolean, force?: boolean }
--- @return table summary { total_code, total_todo, orphan_code, orphan_todo, missing_files, summary }
function M.validate_all_links(opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	local all_code = M.get_all_code_links()
	local all_todo = M.get_all_todo_links()

	local summary = {
		total_code = 0,
		total_todo = 0,
		orphan_code = 0,
		orphan_todo = 0,
		missing_files = 0,
	}

	-- 代码链接检查
	for id, link in pairs(all_code) do
		summary.total_code = summary.total_code + 1

		if vim.fn.filereadable(M._normalize_path(link.path)) == 0 then
			summary.missing_files = summary.missing_files + 1
			if verbose then
				vim.notify("todo2: 代码链接文件不存在: " .. link.path, vim.log.levels.DEBUG)
			end
		end

		if not all_todo[id] then
			summary.orphan_code = summary.orphan_code + 1
			if verbose then
				vim.notify("todo2: 孤立的代码链接 id=" .. id, vim.log.levels.DEBUG)
			end
		end
	end

	-- TODO 链接检查
	for id, link in pairs(all_todo) do
		summary.total_todo = summary.total_todo + 1

		if vim.fn.filereadable(M._normalize_path(link.path)) == 0 then
			summary.missing_files = summary.missing_files + 1
			if verbose then
				vim.notify("todo2: TODO 链接文件不存在: " .. link.path, vim.log.levels.DEBUG)
			end
		end

		if not all_code[id] then
			summary.orphan_todo = summary.orphan_todo + 1
			if verbose then
				vim.notify("todo2: 孤立的 TODO 链接 id=" .. id, vim.log.levels.DEBUG)
			end
		end
	end

	summary.summary = string.format(
		"链接验证完成：代码=%d，TODO=%d，孤立代码=%d，孤立TODO=%d，缺失文件=%d",
		summary.total_code,
		summary.total_todo,
		summary.orphan_code,
		summary.orphan_todo,
		summary.missing_files
	)

	return summary
end

return M
