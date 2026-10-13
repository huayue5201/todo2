-- lua/todo2/task/mover.lua
-- 任务的复制 / 移动（跨 TODO 文件）：抽屉里 y 复制、d 剪切、p 粘贴。
--
-- 语义约定（贴「文件即真源」）：
--   * 移动（cut）保留任务 id —— 还是同一个任务换了个文件；
--     代码锚点、描述、标签随 id 保留。文件行的增删交给 sync 收敛，
--     本模块不直接增删 store 记录、不写墓碑。
--   * 复制（copy）为整棵子树生成新 id —— 分身是另一个任务；
--     不复制代码锚点（一行代码只能指向一个任务）。
--
-- 抽取的「子树行」= 根任务行到 description.subtree_end（含全部后代与正文块），
-- 是连续的一段文本；粘贴时整体平移缩进即可。

local M = {}

local id_utils = require("todo2.utils.id")
local format = require("todo2.utils.format")
local description = require("todo2.core.description")
local parser = require("todo2.core.parser")
local core = require("todo2.store.task.core")
local sync = require("todo2.core.sync")
local autosave = require("todo2.core.autosave")

---@class todo2.MoveRegister
---@field mode "copy"|"cut"
---@field source_path string 源 TODO 文件
---@field root_id string 子树根任务 id
---@field root_indent number 根任务行的缩进宽度
---@field lines string[] 子树原始行（含正文块）

---@type todo2.MoveRegister|nil
local register = nil

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO)
end

---加载文件到缓冲区并返回 {bufnr, lines}
local function load_buf(path)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	return bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---在已解析的任务列表里按 id 找节点（节点含 children / line_num / indent）
local function find_node(path, lines, id)
	if not id then
		return nil
	end
	local tasks = parser.parse_lines(path, lines)
	for _, t in ipairs(tasks) do
		if t.id == id then
			return t
		end
	end
	return nil
end

---抽取子树：返回行区间与行内容。找不到返回 nil。
local function extract(path, id)
	local _, lines = load_buf(path)
	local node = find_node(path, lines, id)
	if not node then
		return nil
	end
	local start_line = node.line_num
	local end_line = description.subtree_end(lines, node)
	local out = {}
	for i = start_line, end_line do
		out[#out + 1] = lines[i]
	end
	return {
		lines = out,
		root_indent = description.indent_of(lines[start_line]),
		start_line = start_line,
		end_line = end_line,
	}
end

---把子树登记进寄存器。成功返回源路径与行数。
local function stage(mode, id)
	if not id then
		return false
	end
	local task = core.get_task(id)
	local loc = task and task.locations and task.locations.todo
	if not (loc and loc.path) then
		notify("该任务没有 TODO 文件定位，无法复制/移动", vim.log.levels.WARN)
		return false
	end
	local sub = extract(loc.path, id)
	if not sub then
		notify("未能在文件中定位任务，无法复制/移动", vim.log.levels.WARN)
		return false
	end
	register = {
		mode = mode,
		source_path = loc.path,
		root_id = id,
		root_indent = sub.root_indent,
		lines = sub.lines,
	}
	return true, loc.path, #sub.lines, sub
end

---复制当前任务子树到寄存器（不修改源文件）。
---@param id string
function M.yank(id)
	local ok, _, count = stage("copy", id)
	if ok then
		notify(("已复制 %d 行到任务寄存器，切到目标 TODO 文件按 p 粘贴"):format(count))
	end
end

---剪切当前任务子树：立即从源文件移除（Vim `dd` 语义），行内容进寄存器。
---@param id string
function M.cut(id)
	local ok, path, count, sub = stage("cut", id)
	if not ok then
		return
	end
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	vim.api.nvim_buf_set_lines(bufnr, sub.start_line - 1, sub.end_line, false, {})
	autosave.request_save(bufnr)
	notify(("已剪切 %d 行到任务寄存器，切到目标 TODO 文件按 p 粘贴"):format(count))
end

---把整段文本整体平移 delta 个空格（空行不动；缩减不越过该行已有缩进）。
local function shift_indent(line, delta)
	if line == "" or line:match("^%s*$") or delta == 0 then
		return line
	end
	if delta > 0 then
		return string.rep(" ", delta) .. line
	end
	local lead = #(line:match("^%s*") or "")
	local n = math.min(-delta, lead)
	return line:sub(n + 1)
end

---复制时为每个任务行的 mark 换上新 id（父子关系靠缩进，无需重映射引用）。
local function remap_ids(lines)
	local out = {}
	for i, line in ipairs(lines) do
		if format.is_task_line(line) then
			local old_id, mark = id_utils.extract_mark(line)
			if old_id then
				local new_id = id_utils.generate_id()
				local new_mark = mark:sub(1, #mark - #old_id) .. new_id
				line = line:gsub(vim.pesc(mark), new_mark, 1)
			end
		end
		out[i] = line
	end
	return out
end

---把寄存器里的子树粘贴到目标文件。
---@param target_path string 目标 TODO 文件
---@param parent_id string|nil 目标父任务 id；nil 表示追加到文件末尾（顶层）
---@return boolean
function M.paste(target_path, parent_id)
	if not register then
		notify("任务寄存器为空：先按 y 复制或 d 剪切", vim.log.levels.WARN)
		return false
	end
	if not target_path or target_path == "" then
		notify("未找到目标 TODO 文件", vim.log.levels.WARN)
		return false
	end

	local bufnr, tlines = load_buf(target_path)

	-- 复制到自身子树内会破坏结构，禁止
	if register.mode == "copy" and parent_id and target_path == register.source_path then
		local node = find_node(target_path, tlines, register.root_id)
		local pnode = find_node(target_path, tlines, parent_id)
		if node and pnode then
			local start_line = node.line_num
			local end_line = description.subtree_end(tlines, node)
			if pnode.line_num >= start_line and pnode.line_num <= end_line then
				notify("不能把任务复制到它自己的子树内", vim.log.levels.WARN)
				return false
			end
		end
	end

	local base_indent = ""
	local after_line = #tlines
	if parent_id then
		local pnode = find_node(target_path, tlines, parent_id)
		if pnode then
			base_indent = pnode.indent .. "  "
			after_line = description.subtree_end(tlines, pnode)
		else
			notify("目标父任务不存在，已改为追加到文件末尾", vim.log.levels.WARN)
		end
	end

	local payload = register.lines
	if register.mode == "copy" then
		payload = remap_ids(payload)
	end

	local delta = #base_indent - register.root_indent
	local insert = {}
	for i, line in ipairs(payload) do
		insert[i] = shift_indent(line, delta)
	end

	vim.api.nvim_buf_set_lines(bufnr, after_line, after_line, false, insert)
	autosave.request_save(bufnr)

	-- 先同步源（剪切时）再同步目标：源侧的 handle_removed_tasks 对无代码锚点的
	-- 任务会整条删除，随后目标侧重建；有锚点的则只解除 TODO 定位，目标侧改指过去。
	-- 反序（先目标）会让源侧看到自己旧索引里的 id、误当成“已删除”而删掉刚移动的任务。
	local paths = {}
	if register.mode == "cut" and register.source_path ~= target_path then
		paths[#paths + 1] = register.source_path
	end
	paths[#paths + 1] = target_path
	for _, p in ipairs(paths) do
		pcall(sync.sync_todo_file, p)
	end

	local mode = register.mode
	local count = #payload
	if mode == "cut" then
		register = nil -- 移动只生效一次，避免重复粘贴出重复 id
	end
	notify(
		("已%s %d 行到 %s"):format(
			mode == "cut" and "移动" or "复制",
			count,
			vim.fn.fnamemodify(target_path, ":t")
		)
	)
	return true
end

---寄存器是否非空
---@return boolean
function M.has_register()
	return register ~= nil
end

---当前寄存器模式（"copy"|"cut"|nil）
---@return string|nil
function M.mode()
	return register and register.mode or nil
end

---清空寄存器
function M.clear()
	register = nil
end

return M
