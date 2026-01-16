-- lua/todo2/store.lua
--- @module todo2.store
--- @brief 基于 nvim-store3 的双链存储层（增强：支持上下文指纹 v2）

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
		-- 可加调试日志
	end
end)

----------------------------------------------------------------------
-- 常量与内部工具
----------------------------------------------------------------------

local LINK_TYPES = {
	CODE_TO_TODO = "code_to_todo",
	TODO_TO_CODE = "todo_to_code",
}

--- 归一化路径
function M._normalize_path(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function get_project_root()
	local store = get_store()
	local meta = store:get("todo.meta") or {}
	if meta.project_root and meta.project_root ~= "" then
		return meta.project_root
	end
	return vim.fn.getcwd()
end

----------------------------------------------------------------------
-- ⭐ 专业版稳健级：上下文指纹系统 v2
----------------------------------------------------------------------

--- 文本清洗：去注释、压缩空白
local function normalize(s)
	if not s then
		return ""
	end
	s = s:gsub("%-%-.*$", "") -- 去掉 Lua 注释
	s = s:gsub("^%s+", "") -- 去掉前空白
	s = s:gsub("%s+$", "") -- 去掉后空白
	s = s:gsub("%s+", " ") -- 压缩空白
	return s
end

--- 稳定哈希（轻量）
local function hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 131 + s:byte(i)) % 2 ^ 31
	end
	return tostring(h)
end

--- 提取结构路径（function/class/module）
local function extract_struct(lines)
	local path = {}

	for _, line in ipairs(lines) do
		local l = normalize(line)

		-- function foo.bar.baz(...)
		local f1 = l:match("^function%s+([%w_%.]+)%s*%(")
		if f1 then
			table.insert(path, "func:" .. f1)
		end

		-- local function foo(...)
		local f2 = l:match("^local%s+function%s+([%w_%.]+)")
		if f2 then
			table.insert(path, "local_func:" .. f2)
		end

		-- M.xxx = function(...)
		local f3 = l:match("^([%w_%.]+)%s*=%s*function%s*%(")
		if f3 then
			table.insert(path, "assign_func:" .. f3)
		end

		-- class-like patterns
		local c1 = l:match("^([%w_]+)%s*=%s*{}$")
		if c1 then
			table.insert(path, "class:" .. c1)
		end
	end

	if #path == 0 then
		return nil
	end
	return table.concat(path, " > ")
end

--- ⭐ 构建上下文指纹（稳健版）
function M.build_context(prev, curr, next)
	prev = prev or ""
	curr = curr or ""
	next = next or ""

	-- 上下文窗口（3 行）
	local n_prev = normalize(prev)
	local n_curr = normalize(curr)
	local n_next = normalize(next)

	local window = table.concat({ n_prev, n_curr, n_next }, "\n")
	local window_hash = hash(window)

	local struct_path = extract_struct({ prev, curr, next })

	return {
		raw = { prev = prev, curr = curr, next = next },

		fingerprint = {
			hash = hash(window_hash .. (struct_path or "")),
			struct = struct_path,
			n_prev = n_prev,
			n_curr = n_curr,
			n_next = n_next,
			window_hash = window_hash,
		},
	}
end

--- ⭐ 指纹匹配（稳健版）
function M.context_match(old_ctx, new_ctx)
	if not old_ctx or not new_ctx then
		return false
	end

	local o = old_ctx.fingerprint
	local n = new_ctx.fingerprint

	-- 兼容旧数据
	if not o or not n then
		return old_ctx.raw.curr == new_ctx.raw.curr
	end

	-- 1. 主哈希完全一致 → 强匹配
	if o.hash == n.hash then
		return true
	end

	-- 2. 结构路径一致 → 强匹配
	if o.struct and n.struct and o.struct == n.struct then
		return true
	end

	-- 3. 上下文相似度（≥2 即匹配）
	local score = 0
	if o.n_curr == n.n_curr then
		score = score + 2
	end
	if o.n_prev == n.n_prev then
		score = score + 1
	end
	if o.n_next == n.n_next then
		score = score + 1
	end

	return score >= 2
end

----------------------------------------------------------------------
-- 初始化
----------------------------------------------------------------------

function M.init()
	local store = get_store()
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

	return true
end

----------------------------------------------------------------------
-- 文件索引维护
----------------------------------------------------------------------

local function add_id_to_file_index(index_ns, filepath, id)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store:get(key) or {}

	for _, existing in ipairs(list) do
		if existing == id then
			return
		end
	end

	table.insert(list, id)
	store:set(key, list)
end

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
-- 自动重新定位（文件移动）
----------------------------------------------------------------------

local function relocate_link_if_needed(link, opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	if not link or not link.path then
		return link
	end

	local norm = M._normalize_path(link.path)
	if vim.fn.filereadable(norm) == 1 then
		return link
	end

	local project_root = get_project_root()
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

	local new_path = matches[1]
	link.path = M._normalize_path(new_path)
	link.updated_at = os.time()

	local store = get_store()
	if link.type == LINK_TYPES.CODE_TO_TODO then
		store:set("todo.links.code." .. link.id, link)
	else
		store:set("todo.links.todo." .. link.id, link)
	end

	return link
end

----------------------------------------------------------------------
-- 添加链接（增强：支持 context）
----------------------------------------------------------------------

function M.add_todo_link(id, data)
	local store = get_store()
	local now = os.time()

	local link = {
		id = id,
		type = LINK_TYPES.TODO_TO_CODE,
		path = M._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
		context = data.context,
	}

	store:set("todo.links.todo." .. id, link)
	add_id_to_file_index("todo.index.file_to_todo", link.path, id)

	local meta = store:get("todo.meta") or {}
	meta.total_links = (meta.total_links or 0) + 1
	meta.last_sync = now
	store:set("todo.meta", meta)

	return true
end

function M.add_code_link(id, data)
	local store = get_store()
	local now = os.time()

	local link = {
		id = id,
		type = LINK_TYPES.CODE_TO_TODO,
		path = M._normalize_path(data.path),
		line = data.line,
		content = data.content or "",
		created_at = data.created_at or now,
		updated_at = now,
		active = true,
		context = data.context,
	}

	store:set("todo.links.code." .. id, link)
	add_id_to_file_index("todo.index.file_to_code", link.path, id)

	local meta = store:get("todo.meta") or {}
	meta.total_links = (meta.total_links or 0) + 1
	meta.last_sync = now
	store:set("todo.meta", meta)

	return true
end

----------------------------------------------------------------------
-- 获取链接（保持原逻辑 + auto_relocate）
----------------------------------------------------------------------

function M.get_todo_link(id, opts)
	local store = get_store()
	local link = store:get("todo.links.todo." .. id)
	if not link then
		return nil
	end
	if opts and opts.force_relocate then
		link = relocate_link_if_needed(link, opts)
	end
	return link
end

function M.get_code_link(id, opts)
	local store = get_store()
	local link = store:get("todo.links.code." .. id)
	if not link then
		return nil
	end
	if opts and opts.force_relocate then
		link = relocate_link_if_needed(link, opts)
	end
	return link
end

function M.get_link(kind, id, opts)
	if kind == "todo" then
		return M.get_todo_link(id, opts)
	elseif kind == "code" then
		return M.get_code_link(id, opts)
	end
	return nil
end

----------------------------------------------------------------------
-- 批量查询
----------------------------------------------------------------------

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
-- 按文件查询
----------------------------------------------------------------------

function M.find_todo_links_by_file(filepath)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local ids = store:get("todo.index.file_to_todo." .. norm) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = M.get_todo_link(id)
		if link then
			table.insert(results, {
				id = id,
				path = link.path,
				line = link.line,
				content = link.content,
				context = link.context,
			})
		end
	end

	return results
end

function M.find_code_links_by_file(filepath)
	local store = get_store()
	local norm = M._normalize_path(filepath)
	local ids = store:get("todo.index.file_to_code." .. norm) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = M.get_code_link(id)
		if link then
			table.insert(results, {
				id = id,
				path = link.path,
				line = link.line,
				content = link.content,
				context = link.context,
			})
		end
	end

	return results
end

----------------------------------------------------------------------
-- 删除链接
----------------------------------------------------------------------

function M.delete_todo_link(id)
	local store = get_store()
	local key = "todo.links.todo." .. id
	local link = store:get(key)
	if not link then
		return
	end
	remove_id_from_file_index("todo.index.file_to_todo", link.path, id)
	store:delete(key)
end

function M.delete_code_link(id)
	local store = get_store()
	local key = "todo.links.code." .. id
	local link = store:get(key)
	if not link then
		return
	end
	remove_id_from_file_index("todo.index.file_to_code", link.path, id)
	store:delete(key)
end

----------------------------------------------------------------------
-- 清理 / 验证
----------------------------------------------------------------------

function M.cleanup(days)
	local store = get_store()
	local now = os.time()
	local threshold = now - days * 86400
	local cleaned = 0

	for id, link in pairs(M.get_all_code_links()) do
		if (link.created_at or 0) < threshold then
			M.delete_code_link(id)
			cleaned = cleaned + 1
		end
	end

	for id, link in pairs(M.get_all_todo_links()) do
		if (link.created_at or 0) < threshold then
			M.delete_todo_link(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

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

	for id, link in pairs(all_code) do
		summary.total_code = summary.total_code + 1
		if vim.fn.filereadable(M._normalize_path(link.path)) == 0 then
			summary.missing_files = summary.missing_files + 1
			if verbose then
				vim.notify("缺失代码文件: " .. (link.path or "<?>"), vim.log.levels.DEBUG)
			end
		end
		if not all_todo[id] then
			summary.orphan_code = summary.orphan_code + 1
			if verbose then
				vim.notify("孤立代码标记: " .. id, vim.log.levels.DEBUG)
			end
		end
	end

	for id, link in pairs(all_todo) do
		summary.total_todo = summary.total_todo + 1
		if vim.fn.filereadable(M._normalize_path(link.path)) == 0 then
			summary.missing_files = summary.missing_files + 1
			if verbose then
				vim.notify("缺失 TODO 文件: " .. (link.path or "<?>"), vim.log.levels.DEBUG)
			end
		end
		if not all_code[id] then
			summary.orphan_todo = summary.orphan_todo + 1
			if verbose then
				vim.notify("孤立 TODO 标记: " .. id, vim.log.levels.DEBUG)
			end
		end
	end

	summary.summary = string.format(
		"代码标记: %d, TODO 标记: %d, 孤立代码: %d, 孤立 TODO: %d, 缺失文件: %d",
		summary.total_code,
		summary.total_todo,
		summary.orphan_code,
		summary.orphan_todo,
		summary.missing_files
	)

	return summary
end

----------------------------------------------------------------------
-- 子任务结构：父子关系持久化
----------------------------------------------------------------------

--- 写入 / 更新某个任务 ID 的结构信息
--- @param id string  任务 ID（{#id} 中的 id）
--- @param data table { parent_id?: string, children?: string[], order?: integer, depth?: integer }
function M.set_task_structure(id, data)
	local store = get_store()
	if not id or id == "" then
		return
	end

	local key = "todo.tasks." .. id
	local existing = store:get(key) or {}

	existing.parent_id = data.parent_id or nil
	existing.children = data.children or {}
	existing.order = data.order
	existing.depth = data.depth

	store:set(key, existing)
end

--- 读取某个任务 ID 的结构信息
--- @param id string
--- @return table|nil
function M.get_task_structure(id)
	if not id or id == "" then
		return nil
	end
	local store = get_store()
	return store:get("todo.tasks." .. id)
end

return M
