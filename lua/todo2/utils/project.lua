-- lua/todo2/utils/project.lua
-- 项目身份：一个项目在 ~/.todo-files 下的目录名是怎么来的。
--
-- 身份（identity）决定目录名，原则是「同一份代码，换个路径/换台机器还是同一个项目」：
--   1. 有 git 远端  → `<host>/<owner>/<repo>[#子目录]`
--   2. 没有远端     → `local:<项目根绝对路径>`
-- 目录名 = `<slug>--<sha256(identity) 前 8 位>`，人可读（slug 取项目根目录名）
-- 且不撞车（同名项目、同名 but 不同远端都不会串）。
--
-- 项目根沿用 nvim-store3 的判定（`.git` / `package.json` / `Cargo.toml` …），
-- 保证 TODO 文件与 store 落在同一个项目上，monorepo 子包也各归各的。
--
-- 每个项目目录里写一份 `.project.json`（身份 / 根路径 / 展示名）：
-- 目录名里的 hash 是身份算出来的，没有它就无法反推「这个目录属于哪个项目」，
-- 项目从磁盘消失之后就判断不了该不该清理（见 store 侧 GC）。

local M = {}

local git = require("todo2.integrations.git")

---@class ProjectInfo
---@field name string ~/.todo-files 下的目录名
---@field label string 展示名（项目根目录名）
---@field dir string 目录绝对路径
---@field root string 项目根
---@field identity string 身份串

local MANIFEST = ".project.json"
local SLUG_MAX = 40

local identity_cache = {}

local function uv()
	return vim.uv or vim.loop
end

--- 去掉结尾分隔符并解析软链（macOS 的 /var → /private/var）。
---@param path string
---@return string
local function real_dir(path)
	local p = vim.fn.fnamemodify(path, ":p")
	p = p:gsub("[/\\]+$", "")
	if p == "" then
		p = "/"
	end
	local real = uv() and uv().fs_realpath and uv().fs_realpath(p)
	if real and real ~= "" then
		p = real:gsub("[/\\]+$", "")
	end
	return p
end

--- 项目根：沿用 nvim-store3 的判定，保证与 store 同根。
---@param path string|nil 目录或文件（默认 cwd）
---@return string
function M.get_project_root(path)
	local start = path
	if start == nil or start == "" then
		start = vim.fn.getcwd()
	end

	local ok, store_path = pcall(require, "nvim-store3.util.path")
	if ok and store_path and store_path.project_root then
		local ok_root, root = pcall(store_path.project_root, start)
		if ok_root and root and root ~= "" then
			return root
		end
	end
	return real_dir(start)
end

--- 远端地址归一化：去掉协议、认证信息、端口、`.git` 后缀。
---@param url string|nil
---@return string|nil
local function normalize_remote(url)
	url = vim.trim(url or "")
	if url == "" then
		return nil
	end

	local host, rest
	-- scp 风格：git@github.com:owner/repo.git
	local scp_host, scp_path = url:match("^[^/@]+@([^/:]+):(.+)$")
	if scp_host then
		host, rest = scp_host, scp_path
	else
		-- scheme://[user[:pass]@]host[:port]/path
		local body = url:match("^[%w+.%-]+://(.+)$")
		if not body then
			return nil -- 本地路径远端：换个机器就不是同一个项目了，不算身份
		end
		body = body:gsub("^[^/@]*@", "")
		local h, p = body:match("^([^/]+)(/.*)$")
		if not h then
			return nil
		end
		host, rest = h:gsub(":%d+$", ""), p
	end

	rest = rest:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
	if rest == "" then
		return nil
	end
	return host:lower() .. "/" .. rest
end

--- 项目身份串。仓库内的子项目会带上相对路径，所以 monorepo 各子包互不串。
---@param path string|nil
---@return string
function M.get_identity(path)
	local root = M.get_project_root(path)
	local cached = identity_cache[root]
	if cached then
		return cached
	end

	local identity
	local toplevel = git.toplevel(root)
	local remote = toplevel and normalize_remote(git.remote_url(toplevel))
	if remote then
		-- git 的 toplevel 与项目根可能一个解析了符号链接、一个没有，只认真正的前缀
		local rel = root:sub(1, #toplevel + 1) == toplevel .. "/" and root:sub(#toplevel + 2) or ""
		identity = rel ~= "" and (remote .. "#" .. rel) or remote
	else
		identity = "local:" .. root
	end

	identity_cache[root] = identity
	return identity
end

--- 目录名里的可读部分。
---@param root string
---@return string
local function slug_of(root)
	local base = vim.fn.fnamemodify(root, ":t"):lower()
	base = base:gsub("[^%w%-%._]", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if base == "" then
		base = "project"
	end
	if #base > SLUG_MAX then
		base = base:sub(1, SLUG_MAX):gsub("%-+$", "")
	end
	return base
end

--- 由身份算目录名：`<slug>--<hash8>`。
---@param root string
---@param identity string
---@return string
local function name_of(root, identity)
	local hash = vim.fn.sha256(identity):sub(1, 8)
	return slug_of(root) .. "--" .. hash
end

--- 当前（或指定路径所属）项目在 ~/.todo-files 下的目录名。
---@param path string|nil
---@return string
function M.get_project_name(path)
	local root = M.get_project_root(path)
	return name_of(root, M.get_identity(root))
end

--- 项目注册表键：绝对路径 + 去尾斜杠 + 解析符号链接。
--- 注册表（~/.cache/nvim/todo2/projects.json）用它做键，避免「同名目录互相覆盖」。
---@param path string|nil 目录（默认 cwd）
---@return string|nil
function M.get_project_key(path)
	local raw = path
	if raw == nil or raw == "" then
		raw = vim.fn.getcwd()
	end
	if raw == nil or raw == "" then
		return nil
	end
	return real_dir(raw)
end

--- 路径的 basename
---@param path string
---@return string
function M.basename(path)
	return (path:gsub("(.)/+$", "%1"):match("([^/]+)$") or path)
end

--- 读取项目目录里的清单
---@param dir string
---@return table|nil
local function read_manifest(dir)
	local path = dir .. "/" .. MANIFEST
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	local ok_decode, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok_decode or type(data) ~= "table" then
		return nil
	end
	return data
end

--- 写入/修复项目清单（内容没变就不写；目录不存在则跳过）。
---@param info ProjectInfo
---@return boolean written|needed
function M.write_manifest(info)
	if not info or not info.dir or vim.fn.isdirectory(info.dir) == 0 then
		return false
	end
	local dir = info.dir
	local want = {
		name = info.name,
		label = info.label,
		identity = info.identity,
		root = info.root,
	}
	local have = read_manifest(dir)
	if
		have
		and have.name == want.name
		and have.label == want.label
		and have.identity == want.identity
		and have.root == want.root
	then
		return false
	end
	local ok, encoded = pcall(vim.json.encode, want)
	if not ok then
		return false
	end
	pcall(vim.fn.writefile, { encoded }, dir .. "/" .. MANIFEST)
	return true
end

--- 项目 TODO 目录。
--- 当前项目的目录会顺带把清单（.project.json）修复成最新；别的项目只读不写。
---@param name string|nil 目录名（默认当前项目）
---@return string
function M.get_project_dir(name)
	local info = M.current()
	local dir = (name == nil or name == "" or name == info.name) and info.dir
		or vim.fn.expand("~/.todo-files/" .. name)
	if dir == info.dir then
		M.write_manifest(info)
	end
	return dir
end

--- 当前项目信息。
---@return ProjectInfo
function M.current()
	local root = M.get_project_root()
	local identity = M.get_identity(root)
	local name = name_of(root, identity)
	return {
		name = name,
		label = M.basename(root),
		dir = vim.fn.expand("~/.todo-files/" .. name),
		root = root,
		identity = identity,
	}
end

--- 列出所有项目目录（跳过隐藏目录：备份 / 隔离区）。
---@return ProjectInfo[]
function M.list_projects()
	local out = {}
	local root_dir = vim.fn.expand("~/.todo-files")
	if vim.fn.isdirectory(root_dir) ~= 1 then
		return out
	end

	local handle = uv().fs_scandir(root_dir)
	if not handle then
		return out
	end
	while true do
		local name = uv().fs_scandir_next(handle)
		if not name then
			break
		end
		if name:sub(1, 1) ~= "." then
			local dir = root_dir .. "/" .. name
			if vim.fn.isdirectory(dir) == 1 then
				local manifest = read_manifest(dir) or {}
				out[#out + 1] = {
					name = name,
					label = manifest.label or name,
					dir = dir,
					root = manifest.root,
					identity = manifest.identity,
				}
			end
		end
	end
	table.sort(out, function(a, b)
		return (a.label or "") < (b.label or "")
	end)
	return out
end

return M
