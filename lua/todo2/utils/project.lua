-- lua/todo2/utils/project.lua
-- 项目身份（identity）与项目目录名（`<slug>--<hash8>`）的判定都在
-- nvim-store3.util.project 里 —— 那是 todo2 与其它消费同一套项目的插件
-- （例如笔记插件）共用的实现。本模块只负责 todo2 自己的部分：
--
--   * TODO 文件仓库路径（`~/.todo-files`）
--   * 由身份推出的 TODO 目录，以及 `.project.json` 清单的维护时机
--     （当前项目的目录在取用时顺手修复清单；别的项目只读不写）
--   * MCP 注册表键（realpath）
--
-- 目录名里的 hash 是身份算出来的，没有清单就无法反推「这个目录属于哪个项目」，
-- 项目从磁盘消失之后就判断不了该不该回收（见 store/project_gc.lua）。

local M = {}

local shared = require("nvim-store3.util.project")

---@class ProjectInfo : StoreProjectInfo
---@field dir string TODO 目录绝对路径

--- 项目根：沿用 nvim-store3 的判定，保证 TODO 文件与 store 落在同一个项目上。
---@param path? string
---@return string
function M.get_project_root(path)
	return shared.root(path)
end

--- 项目身份串（远端优先，无远端回退 `local:<根>`）。
---@param path? string
---@return string
function M.get_identity(path)
	return shared.identity(path)
end

--- 当前（或指定路径所属）项目在 ~/.todo-files 下的目录名。
---@param path? string
---@return string
function M.get_project_name(path)
	return shared.name(path)
end

--- 项目注册表键：绝对路径 + 去尾斜杠 + 解析符号链接。
--- 注册表（~/.cache/nvim/todo2/projects.json）用它做键，避免「同名目录互相覆盖」。
---@param path? string
---@return string|nil
function M.get_project_key(path)
	local raw = path
	if raw == nil or raw == "" then
		raw = vim.fn.getcwd()
	end
	if raw == nil or raw == "" then
		return nil
	end
	return shared.realpath(raw)
end

--- 路径的 basename
---@param path string
---@return string
function M.basename(path)
	return shared.basename(path)
end

--- 读到目录里的项目清单（没有 / 坏了都返回 nil）。
---@param dir string
---@return table|nil
function M.read_manifest(dir)
	return shared.read_manifest(dir)
end

--- TODO 文件仓库的根目录。
---@return string
function M.vault_root()
	return vim.fn.expand("~/.todo-files")
end

--- 写入/修复项目清单（内容没变就不写；目录不存在则跳过）。
---@param info ProjectInfo
---@return boolean written
function M.write_manifest(info)
	if not info then
		return false
	end
	return shared.write_manifest(info.dir, info)
end

--- 项目 TODO 目录。
--- 当前项目的目录会顺带把清单（.project.json）修复成最新；别的项目只读不写。
---@param name? string 目录名（默认当前项目）
---@return string
function M.get_project_dir(name)
	local info = M.current()
	local dir = (name == nil or name == "" or name == info.name) and info.dir or M.vault_root() .. "/" .. name
	if dir == info.dir then
		M.write_manifest(info)
	end
	return dir
end

--- 当前项目信息。
---@return ProjectInfo
function M.current()
	local info = shared.info()
	info.dir = M.vault_root() .. "/" .. info.name
	return info
end

--- 列出所有项目目录（跳过隐藏目录：备份 / 隔离区）。
---@return ProjectInfo[]
function M.list_projects()
	local out = shared.list(M.vault_root())
	for _, info in ipairs(out) do
		info.dir = M.vault_root() .. "/" .. info.name
	end
	return out
end

return M
