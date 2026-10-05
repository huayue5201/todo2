-- lua/todo2/ai/anchors.lua
-- todo2 AI 层的「代码锚点硬约束」：任务必须绑定到真实代码。
--
-- 供 MCP server / 编辑器内 AI 适配 / CLI pipe 复用：
--   * 创建任务时强制 anchor = { path, line }，缺失/越界直接报错；
--   * 创建/绑定后立即重新核验（code_tracker.reanchor），把 stale 刷成 ok / lost，
--     并把核验后的「真实」锚点状态回读给调用方；
--   * 提供一次性建整棵带锚点任务树（先整树校验再落库）、以及批量核验的入口。
--
-- 与动作层（todo2.ai.actions）解耦：这里只加「约束 + 核验」，不重复实现落库。

local M = {}

local actions = require("todo2.ai.actions")
local core = require("todo2.store.task.core")
local query = require("todo2.store.task.query")
local file = require("todo2.utils.file")

local ANCHOR_REQUIRED = "anchor {path,line} is required: every todo2 task must be linked to "
	.. "real code. Point it at the exact 1-based line of the relevant symbol "
	.. "(function/struct/const/field). "

--- 校验 anchor 形状：{ path: string, line: integer }。
---@param a any
---@return boolean
function M.is_anchor(a)
	return type(a) == "table"
		and type(a.path) == "string"
		and a.path ~= ""
		and tonumber(a.line) ~= nil
end

--- 预检锚点是否指向真实代码（文件存在、行号在范围内）。
--- 在落库前调用，避免任务建好了才发现锚点非法。
---@param path string 已归一化的路径
---@param line integer
---@return string|nil err
local function validate_anchor(path, line)
	if path == "" then
		return "anchor path is empty"
	end
	if vim.fn.filereadable(path) == 0 then
		return "code file not found: " .. path
	end
	local lines = file.read_lines_smart(path)
	local total = lines and #lines or 0
	if total == 0 then
		return "code file is empty or unreadable: " .. path
	end
	if line < 1 or line > total then
		return ("line %d out of range (1..%d) for %s"):format(line, total, path)
	end
	return nil
end

--- 回读某任务当前生效的代码锚点（含真实状态）。
---@param id string
---@return table|nil { source, state, path, line }
local function read_anchor(id)
	local task = core.get_task(id)
	if not task then
		return nil
	end

	local loc, inherited = query.resolve_code_location(id)
	if loc then
		return {
			source = inherited and "inherited" or "own",
			state = inherited and "inherited" or core.anchor_state(task),
			path = loc.path,
			line = loc.line,
		}
	end

	local own = task.locations and task.locations.code
	if own then
		return { source = "own", state = core.ANCHOR.LOST, path = own.path, line = own.line }
	end
	return nil
end

--- 对一个文件重新核验锚点（stale → ok / lost）。返回受影响的任务数。
--- 路径先归一化，保证与 actions 落库时保存的路径一致；
--- 只回收本层临时加载的 buffer，不动用户已打开/显示的 buffer。
---@param path string
---@return integer affected
function M.reanchor_file(path)
	path = file.normalize_path(path)
	if path == "" or vim.fn.filereadable(path) == 0 then
		return 0
	end

	local b = vim.fn.bufadd(path)
	local was_loaded = vim.api.nvim_buf_is_loaded(b)
	if not was_loaded then
		vim.fn.bufload(b)
	end

	local affected = require("todo2.core.code_tracker").reanchor(b)

	if not was_loaded and vim.api.nvim_buf_is_valid(b) then
		pcall(vim.api.nvim_buf_delete, b, { force = true })
	end

	return #(affected or {})
end

--- 确保任务的锚点是「自己名下、且已核验」的。去重重用已有任务时 actions
--- 不会再绑定锚点，这里补绑一次，硬约束才算真正落地。
---@param id string
---@param path string 已归一化
---@param line integer
---@return string|nil err
local function ensure_anchor(id, path, line)
	local cur = read_anchor(id)
	if cur and cur.source == "own" then
		return nil
	end
	local _, e = actions.link_code(id, path, line)
	return e
end

--- 创建任务并强制绑定代码锚点；创建后立即核验，使锚点状态为 ok。
---@param opts table { content, parent_id?, path?, allow_duplicate?, anchor = {path,line} }
---@return table|nil result, string|nil err
function M.create_task(opts)
	opts = opts or {}
	if type(opts.content) ~= "string" or opts.content == "" then
		return nil, "content is required"
	end
	if not M.is_anchor(opts.anchor) then
		return nil, ANCHOR_REQUIRED
	end

	local anchor_path = file.normalize_path(opts.anchor.path)
	local anchor_line = math.floor(tonumber(opts.anchor.line))
	local verr = validate_anchor(anchor_path, anchor_line)
	if verr then
		return nil, verr
	end

	local r, e = actions.create_task({
		content = opts.content,
		parent_id = opts.parent_id,
		path = opts.path,
		allow_duplicate = opts.allow_duplicate,
		anchor = { path = anchor_path, line = anchor_line },
	})
	if not r then
		return nil, e
	end
	if r.warning then
		-- actions 只在链接失败时给 warning；不能吞掉，否则违反硬约束。
		return nil, r.warning
	end

	if r.deduped then
		local aerr = ensure_anchor(r.id, anchor_path, anchor_line)
		if aerr then
			return nil, aerr
		end
	end

	r.reanchored = M.reanchor_file(anchor_path)
	r.anchor = read_anchor(r.id) or { source = "own", state = core.ANCHOR.LOST, path = anchor_path, line = anchor_line }
	r.ok = true
	return r
end

--- 绑定代码锚点并立即核验。
---@param id string
---@param path string
---@param line integer
---@return table|nil result, string|nil err
function M.link_code(id, path, line)
	if not M.is_anchor({ path = path, line = line }) then
		return nil, ANCHOR_REQUIRED
	end

	local p = file.normalize_path(path)
	local l = math.floor(tonumber(line))
	local verr = validate_anchor(p, l)
	if verr then
		return nil, verr
	end

	local r, e = actions.link_code(id, p, l)
	if not r then
		return nil, e
	end

	r.reanchored = M.reanchor_file(p)
	r.anchor = read_anchor(id) or { source = "own", state = core.ANCHOR.LOST, path = p, line = l }
	r.ok = true
	return r
end

--- 递归创建带锚点的任务树（每个节点都必须有 anchor）。
--- 先整树校验再落库，避免「建了一半才发现节点非法」；万一落库中途失败，
--- 会 best-effort 回滚已创建节点。
---@param opts table { tasks = node[], parent_id?, path?, allow_duplicate? }
---@field node { content: string, anchor: {path:string,line:integer}, status?: string, children?: node[] }
---@return table|nil result, string|nil err
function M.create_task_tree(opts)
	opts = opts or {}
	if type(opts.tasks) ~= "table" or #opts.tasks == 0 then
		return nil, "tasks (non-empty array) is required"
	end

	local verr

	local function validate(node)
		if verr then
			return
		end
		if type(node) ~= "table" or type(node.content) ~= "string" or node.content == "" then
			verr = "each node needs a non-empty content"
			return
		end
		if not M.is_anchor(node.anchor) then
			verr = ANCHOR_REQUIRED .. "Offending task: " .. tostring(node.content)
			return
		end
		local p = file.normalize_path(node.anchor.path)
		local l = math.floor(tonumber(node.anchor.line))
		local e = validate_anchor(p, l)
		if e then
			verr = e .. " (offending task: " .. node.content .. ")"
			return
		end
		for _, child in ipairs(node.children or {}) do
			validate(child)
		end
	end

	for _, node in ipairs(opts.tasks) do
		validate(node)
		if verr then
			break
		end
	end
	if verr then
		return nil, verr
	end

	local created = {}
	local files = {}
	local failed

	local function make(node, parent_id)
		if failed then
			return
		end

		local p = file.normalize_path(node.anchor.path)
		local l = math.floor(tonumber(node.anchor.line))

		local r, e = actions.create_task({
			content = node.content,
			parent_id = parent_id,
			path = opts.path,
			allow_duplicate = opts.allow_duplicate,
			anchor = { path = p, line = l },
		})
		if not r then
			failed = e
			return
		end
		if r.warning then
			failed = r.warning
			return
		end
		if r.deduped then
			local aerr = ensure_anchor(r.id, p, l)
			if aerr then
				failed = aerr
				return
			end
		end

		if node.status then
			pcall(actions.set_status, r.id, node.status)
		end

		created[#created + 1] = { id = r.id, content = node.content, status = node.status, path = p, line = l }
		files[p] = true

		for _, child in ipairs(node.children or {}) do
			make(child, r.id)
		end
	end

	for _, node in ipairs(opts.tasks) do
		make(node, opts.parent_id)
		if failed then
			break
		end
	end

	-- 无论成功失败，都对已触及的文件核验一遍，避免留下未核验的锚点。
	local verified = 0
	for p in pairs(files) do
		verified = verified + M.reanchor_file(p)
	end

	if failed then
		if #created > 0 then
			local ids = vim.tbl_map(function(c)
				return c.id
			end, created)
			pcall(function()
				require("todo2.task.deleter").delete_by_ids(ids)
			end)
		end
		return nil, failed
	end

	for _, c in ipairs(created) do
		c.anchor = read_anchor(c.id) or { source = "own", state = core.ANCHOR.LOST, path = c.path, line = c.line }
		c.path = nil
		c.line = nil
	end

	return { ok = true, created = created, files = vim.tbl_keys(files), reanchored = verified }
end

--- 重新核验锚点：给定 path 则只核验该文件，否则核验所有带锚点的文件。
---@param opts table { path? }
---@return table
function M.verify(opts)
	opts = opts or {}
	local paths = {}
	if opts.path and opts.path ~= "" then
		paths[file.normalize_path(opts.path)] = true
	else
		for _, t in ipairs(require("todo2.ai").list({})) do
			local a = t.anchor
			if a and a.path then
				paths[file.normalize_path(a.path)] = true
			end
		end
	end

	local out = {}
	local total = 0
	for p in pairs(paths) do
		if p ~= "" then
			local n = M.reanchor_file(p)
			total = total + n
			out[#out + 1] = { path = p, affected = n }
		end
	end
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return { ok = true, files = out, affected = total }
end

return M
