-- lua/todo2/store/anchor_sidecar.lua
-- 代码锚点的旁挂存储（每个项目一个 `.anchors.json`）。
--
-- 为什么需要它：
--   任务的「存在性 / 内容 / 状态 / 标签」由 `.todo.md` 承载，而代码锚点
--   （path/line/col/line_text/context…）只能存在 store 里。一旦 store 侧的任务
--   记录丢失（重建、store 迁移、手工清库），`md -> store` 的导入会把它当成新任务
--   重建，锚点随之消失，且无法从 md 恢复。
--   把锚点按 id 另存一份项目级文件，就让锚点也具备了「可恢复」的持久性，
--   而不必往 md 里塞隐藏注释。
--
-- 生命周期：
--   * save_to_new_layout 有代码锚点 -> set
--   * 无代码锚点 / 任务被删 -> remove
--   * sync 因 md 重新创建任务 -> get 并回填
-- 文件很小（每任务一行），读写都直接落盘，不做防抖：它只在锚点增删改时变化。

local M = {}

local project = require("todo2.utils.project")

local FILE_NAME = ".anchors.json"
local cache = {} -- path -> table<id, location>

---@param path string
---@return table<string, table>
local function load(path)
	if cache[path] then
		return cache[path]
	end
	local data = {}
	if vim.fn.filereadable(path) == 1 then
		local ok, decoded = pcall(function()
			local lines = vim.fn.readfile(path)
			return vim.json.decode(table.concat(lines, "\n"))
		end)
		if ok and type(decoded) == "table" then
			data = decoded
		end
	end
	cache[path] = data
	return data
end

---当前项目的旁挂文件路径
---@return string
local function sidecar_path()
	local name = project.get_project_name()
	return project.get_project_dir(name) .. "/" .. FILE_NAME
end

---@param path string
---@param data table<string, table>
local function persist(path, data)
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
	local ok, encoded = pcall(vim.json.encode, data)
	if not ok then
		return
	end
	pcall(vim.fn.writefile, { encoded }, path)
end

---记录/更新某任务的代码锚点
---@param id string
---@param loc table
function M.set(id, loc)
	if type(id) ~= "string" or type(loc) ~= "table" or type(loc.path) ~= "string" then
		return
	end
	local path = sidecar_path()
	local data = load(path)
	data[id] = {
		path = loc.path,
		line = loc.line,
		col = loc.col,
		end_col = loc.end_col,
		snippet = loc.snippet,
		context = loc.context,
		line_text = loc.line_text,
		block_start = loc.block_start,
		block_end = loc.block_end,
	}
	persist(path, data)
end

---删除某任务的代码锚点记录
---@param id string
function M.remove(id)
	if type(id) ~= "string" then
		return
	end
	local path = sidecar_path()
	local data = load(path)
	if data[id] == nil then
		return
	end
	data[id] = nil
	persist(path, data)
end

---读取某任务遗留的代码锚点
---@param id string
---@return table|nil
function M.get(id)
	local data = load(sidecar_path())
	local loc = data[id]
	if type(loc) ~= "table" or type(loc.path) ~= "string" then
		return nil
	end
	return vim.deepcopy(loc)
end

---丢弃内存缓存（项目切换 / 测试用）
function M.reset()
	cache = {}
end

M.FILE_NAME = FILE_NAME

return M
