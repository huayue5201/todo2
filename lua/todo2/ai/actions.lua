-- lua/todo2/ai/actions.lua
-- 写操作层：供 MCP / 外部工具修改任务。
--
-- 都走插件既有 API（service / status / core），保持「TODO 文件 + store」一致。
-- 失败返回 `nil, err`；成功返回结果表。

local M = {}

local core = require("todo2.store.task.core")
local status_domain = require("todo2.core.status")
local types = require("todo2.store.types")
local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local file = require("todo2.utils.file")
local description = require("todo2.core.description")
local format = require("todo2.utils.format")
local tags_utils = require("todo2.utils.tags")
local task_line = require("todo2.utils.task_line")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 找到或加载文件 buffer（不改动 'buflisted'）。
---@param path string
---@return number
local function ensure_buf(path)
	local b = vim.fn.bufnr(path)
	if b == -1 then
		b = vim.fn.bufadd(path)
	end
	if not vim.api.nvim_buf_is_loaded(b) then
		vim.fn.bufload(b)
	end
	return b
end

--- 同步落盘（MCP 需要确定性）。
local function save_buf(bufnr)
	pcall(function()
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("silent! update")
		end)
	end)
end

---@return string|nil
local function default_todo_file()
	local fm = require("todo2.ui.file_manager")
	local project_utils = require("todo2.utils.project")
	return fm.get_todo_files(project_utils.get_project_name())[1]
end

---@return string|nil path, string|nil err
local function resolve_todo_path(opts, parent_id)
	local path
	if parent_id then
		local loc = core.get_todo_location(parent_id)
		if not loc or not loc.path then
			return nil, "找不到父任务的 TODO 位置: " .. tostring(parent_id)
		end
		path = loc.path
	else
		path = opts.path or default_todo_file()
	end

	if not path or path == "" then
		return nil, "没有可用的 TODO 文件（可用 path 指定）"
	end

	-- 统一归一化，避免与 store 中已归一化的路径不一致
	path = file.normalize_path(path)
	if vim.fn.filereadable(path) == 0 then
		return nil, "TODO 文件不存在: " .. path
	end
	return path
end

--- 当前 TODO 文件主区域（非归档）的最后一个任务节点。
---@return table|nil
local function last_main_task(path)
	local tasks = require("todo2.render.scheduler").get_parse_tree(path)
	return tasks and tasks[#tasks] or nil
end

--- 任务自身 + 正文块的最后一行。
local function task_block_end(lines, line_num)
	local block = description.block_at(lines, line_num)
	return block and block.end_line or line_num
end

--- 解析树中指定 id 的节点。
local function parse_node(bufnr, id)
	local path = vim.api.nvim_buf_get_name(bufnr)
	for _, t in ipairs(require("todo2.render.scheduler").get_parse_tree(path)) do
		if t.id == id then
			return t
		end
	end
	return nil
end

--- 子树（含正文）最后一行。
local function subtree_end(lines, node)
	local last = node
	while last.children and #last.children > 0 do
		last = last.children[#last.children]
	end
	return task_block_end(lines, last.line_num)
end

--- 在 TODO 文件里查找「同内容 + 同父级」的已有任务（非归档，按缩进树判定父级）。
--- 用于 create_task 的幂等/去重，防止 Agent 重试重复建任务。
---@param bufnr number
---@param content string
---@param parent_id string|nil
---@return table|nil 已有任务（store 对象）
local function find_duplicate(bufnr, content, parent_id)
	local target = vim.trim(content)
	if target == "" then
		return nil
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	for _, node in ipairs(require("todo2.render.scheduler").get_parse_tree(path)) do
		if node.id then
			local node_parent = node.parent and node.parent.id or nil
			if node_parent == parent_id then
				local t = core.get_task(node.id)
				local c = (t and t.core.content) or node.content or ""
				if vim.trim(c) == target then
					return t
				end
			end
		end
	end
	return nil
end

---@param s string
---@return string|nil
local function resolve_status(s)
	s = tostring(s or ""):lower()
	if s == types.STATUS.COMPLETED or s == types.STATUS.ARCHIVED then
		return s
	end
	for _, def in ipairs(status_domain.get_cycle()) do
		if def.label:lower() == s then
			return def.label
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 创建 TODO 文件
---------------------------------------------------------------------

--- 在当前项目的 TODO 目录下新建一个 TODO 文件（无交互）。
---@param name string 文件名（可省略后缀，会补 .todo.md）
---@return table|nil result { path }
function M.create_todo_file(name)
	name = name and vim.trim(name) or ""
	if name == "" then
		return nil, "name is required"
	end

	local path = require("todo2.ui.file_manager").create_todo_file(name)
	if not path then
		return nil, "创建 TODO 文件失败"
	end
	return { path = path }
end

---------------------------------------------------------------------
-- 创建任务
---------------------------------------------------------------------

---@class todo2.CreateTaskOptions
---@field content string
---@field parent_id? string
---@field path? string
---@field anchor? { path: string, line: integer }
---@field allow_duplicate? boolean 默认 false：同内容 + 同父级的已有任务会被复用（幂等）

--- 创建任务：默认追加到项目第一个 TODO 文件的活跃区；指定 parent_id 则建为其子任务。
--- 默认做内容去重（同内容 + 同父级则复用已有任务），可用 allow_duplicate 关闭。
---@param opts todo2.CreateTaskOptions
---@return table|nil result { id, path, line, deduped? }
function M.create_task(opts)
	opts = opts or {}
	local content = vim.trim(opts.content or "")
	if content == "" then
		return nil, "content is required"
	end

	local path, err = resolve_todo_path(opts, opts.parent_id)
	if not path then
		return nil, err
	end

	local bufnr = ensure_buf(path)

	-- 幂等/去重：同内容 + 同父级的已有任务直接返回（Agent 重试不会重复建）
	if not opts.allow_duplicate then
		local existing = find_duplicate(bufnr, content, opts.parent_id)
		local loc = existing and existing.locations and existing.locations.todo
		if loc then
			return { id = existing.id, path = loc.path, line = loc.line, deduped = true }
		end
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local id = id_utils.generate_id()
	local tags = tags_utils.normalize(opts.tags)

	local after_line, indent
	if opts.parent_id then
		local node = parse_node(bufnr, opts.parent_id)
		if not node then
			return nil, "父任务不在该 TODO 文件中: " .. tostring(opts.parent_id)
		end
		after_line = task_block_end(lines, node.line_num)
		indent = (node.indent or "") .. "  "
	else
		-- 追加到主区域最后一个任务的子树之后（即活跃区底部）
		indent = ""
		local last = last_main_task(path)
		if last then
			after_line = subtree_end(lines, last)
		else
			after_line = math.max(1, #lines)
		end
	end

	local result = service.insert_task_line(bufnr, after_line, {
		indent = indent,
		id = id,
		content = content,
		tags = tags,
		update_store = false,
		trigger_event = false,
		autosave = false,
	})
	if not result then
		return nil, "插入任务行失败"
	end

	service.create_todo_link(path, result.line_num, id, content, { parent_id = opts.parent_id, tags = tags })
	save_buf(bufnr)

	local out = { id = id, path = path, line = result.line_num }

	if opts.anchor and opts.anchor.path and opts.anchor.line then
		local ok, lerr = M.link_code(id, opts.anchor.path, opts.anchor.line)
		if not ok then
			out.warning = lerr
		end
	end

	return out
end

---------------------------------------------------------------------
-- 修改状态
---------------------------------------------------------------------

--- 设置任务状态（活跃 label / completed / archived）。
---@param id string
---@param status string
---@return table|nil result { id, status }
function M.set_status(id, status)
	local target = resolve_status(status)
	if not target then
		return nil, "unknown status: " .. tostring(status)
	end

	local ok, err = status_domain.set_status(id, target, "mcp")
	if not ok then
		return nil, err
	end
	return { id = id, status = target }
end

--- 按提交 sha（或提交消息）关闭其中引用的任务；MCP 显式工具，不受 git.enable 限制。
---@param opts { sha?: string, message?: string }
---@return table|nil result { changed }
function M.complete_by_commit(opts)
	return require("todo2.handlers.git").complete_by_commit(opts)
end

--- 重写任务在 TODO 文件里的整行（改变标签后保持「文件 + store」一致）。
--- 优先改已加载的 buffer（并落盘），否则直接写磁盘。
---@param id string
---@return boolean ok, string|nil err
local function rewrite_todo_line(id)
	return task_line.rewrite(id)
end

---------------------------------------------------------------------
-- 修改标签
---------------------------------------------------------------------

--- 设置任务标签（整体替换）。
---@param id string
---@param tags string[]
---@return table|nil result { id, tags }
function M.set_tags(id, tags)
	if not core.get_task(id) then
		return nil, "task not found: " .. tostring(id)
	end

	core.set_tags(id, tags)
	local ok, err = rewrite_todo_line(id)
	if not ok then
		return nil, err
	end

	require("todo2.core.events").emit("mcp_set_tags", { changed_ids = { id } })
	return { id = id, tags = core.get_task(id).core.tags }
end

--- 添加标签（并集）。
---@param id string
---@param tags string[]
---@return table|nil result { id, tags }
function M.add_tag(id, tags)
	if not core.get_task(id) then
		return nil, "task not found: " .. tostring(id)
	end

	core.add_tags(id, tags)
	local ok, err = rewrite_todo_line(id)
	if not ok then
		return nil, err
	end

	require("todo2.core.events").emit("mcp_set_tags", { changed_ids = { id } })
	return { id = id, tags = core.get_task(id).core.tags }
end

--- 移除标签。
---@param id string
---@param tags string[]
---@return table|nil result { id, tags }
function M.remove_tag(id, tags)
	if not core.get_task(id) then
		return nil, "task not found: " .. tostring(id)
	end

	core.remove_tags(id, tags)
	local ok, err = rewrite_todo_line(id)
	if not ok then
		return nil, err
	end

	require("todo2.core.events").emit("mcp_set_tags", { changed_ids = { id } })
	return { id = id, tags = core.get_task(id).core.tags }
end

---------------------------------------------------------------------
-- 关联代码
---------------------------------------------------------------------

--- 把任务关联到代码位置（复用 create_code_link，异步完成后返回）。
---@param id string
---@param path string
---@param line integer
---@return table|nil result { id, path, line }
function M.link_code(id, path, line)
	local task = core.get_task(id)
	if not task then
		return nil, "task not found: " .. tostring(id)
	end

	path = file.normalize_path(path)
	if vim.fn.filereadable(path) == 0 then
		return nil, "code file not found: " .. path
	end

	local bufnr = ensure_buf(path)
	local lnum = tonumber(line) or 1
	local total = vim.api.nvim_buf_line_count(bufnr)
	if lnum < 1 or lnum > total then
		return nil, ("line %d out of range (1..%d)"):format(lnum, total)
	end

	local done, err = false, nil
	service.create_code_link(bufnr, lnum, id, task.core.content or "", function(ok, e)
		done = true
		if not ok then
			err = e
		end
	end)

	-- create_code_link 是 async 的：泵事件循环等它完成
	vim.wait(3000, function()
		return done
	end, 10)

	if not done then
		return nil, "link_code timed out"
	end
	if err then
		return nil, err
	end
	return { id = id, path = path, line = lnum }
end

--- 一次性迁移：旧「类型状态」(fix/refactor/AI) → 标签 + 默认进度状态。
---@return table result { migrated = number }
function M.migrate_tags()
	return { migrated = require("todo2.core.migrate").run() }
end

return M
