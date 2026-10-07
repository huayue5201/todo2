-- lua/todo2/integrations/git.lua
-- git 命令封装：全插件唯一 shell-out git 的地方。
-- 只负责「取数据」（提交列表 / 脏文件 / 分支 / HEAD），不含任何状态与存储逻辑。
-- 统一同步执行（vim.system + 超时）并对结果做短 TTL 缓存，避免同一轮里重复调用。

local M = {}

local TIMEOUT = 3000
local CACHE_TTL = 2000

---@class GitCommit
---@field sha string 完整 hash
---@field short string 短 hash（7 位）
---@field author string 作者名
---@field date integer 提交时间戳（秒）
---@field message string 完整提交消息（含标题与正文）

local cache = {}

local function cache_get(key)
	local item = cache[key]
	if item and (vim.uv.now() - item.at) < item.ttl then
		return item.value, true
	end
	return nil, false
end

local function cache_set(key, value, ttl)
	cache[key] = { value = value, at = vim.uv.now(), ttl = ttl or CACHE_TTL }
	return value
end

--- 直接执行 git（不做可用性检查，供 available 自身调用）。
---@param args string[]
---@param cwd? string
---@return vim.SystemCompleted|nil
local function run(args, cwd)
	local cmd = { "git" }
	vim.list_extend(cmd, args)

	local ok, proc = pcall(vim.system, cmd, { cwd = cwd, text = true })
	if not ok or not proc then
		return nil
	end

	local ok2, res = pcall(function()
		return proc:wait(TIMEOUT)
	end)
	if not ok2 then
		return nil
	end
	return res
end

--- 当前目录是否在 git 工作区内。
---@param cwd? string
---@return boolean
function M.available(cwd)
	local key = "available:" .. (cwd or vim.fn.getcwd())
	local value, hit = cache_get(key)
	if hit then
		return value
	end

	local res = run({ "rev-parse", "--is-inside-work-tree" }, cwd)
	local ok = res ~= nil and res.code == 0 and (res.stdout or ""):gsub("%s+", "") == "true"
	return cache_set(key, ok, 60000)
end

--- 执行 git 命令，返回 vim.SystemCompleted；非 git 仓库返回 nil。
---@param args string[]
---@param cwd? string
---@return vim.SystemCompleted|nil
function M.exec(args, cwd)
	if not M.available(cwd) then
		return nil
	end
	return run(args, cwd)
end

--- 执行并返回去掉尾部空白的 stdout；失败或为空返回 nil。
---@param args string[]
---@param cwd? string
---@return string|nil
function M.exec_line(args, cwd)
	local res = M.exec(args, cwd)
	if not res or res.code ~= 0 then
		return nil
	end
	local out = (res.stdout or ""):gsub("%s+$", "")
	return out ~= "" and out or nil
end

--- HEAD 的完整 hash。
---@param cwd? string
---@return string|nil
function M.head(cwd)
	return M.exec_line({ "rev-parse", "HEAD" }, cwd)
end

--- 当前分支名（分离 HEAD 时返回 "HEAD"）。
---@param cwd? string
---@return string|nil
function M.branch(cwd)
	return M.exec_line({ "rev-parse", "--abbrev-ref", "HEAD" }, cwd)
end

--- 仓库根目录（绝对路径）。
---@param cwd? string
---@return string|nil
function M.toplevel(cwd)
	return M.exec_line({ "rev-parse", "--show-toplevel" }, cwd)
end

--- ancestor 是否为 descendant 的祖先。
---@param ancestor string
---@param descendant string
---@return boolean
function M.is_ancestor(ancestor, descendant)
	local res = M.exec({ "merge-base", "--is-ancestor", ancestor, descendant })
	return res ~= nil and res.code == 0
end

--- 工作区脏文件集合：规范化绝对路径 → true（含未跟踪文件与重命名目标）。
---@param cwd? string
---@return table<string, boolean>
function M.dirty_files(cwd)
	local key = "dirty:" .. (cwd or vim.fn.getcwd())
	local value, hit = cache_get(key)
	if hit then
		return value
	end

	local file_utils = require("todo2.utils.file")
	local set = {}

	local res = M.exec({ "status", "--porcelain", "--untracked-files=all", "-z" }, cwd)
	if res and res.code == 0 and res.stdout and res.stdout ~= "" then
		local top = M.toplevel(cwd)
		local entries = vim.split(res.stdout, "\0", { plain = true, trimempty = true })
		local i = 1
		while i <= #entries do
			local entry = entries[i]
			if #entry >= 4 then
				local status = entry:sub(1, 2)
				local path = entry:sub(4)
				-- 重命名 / 复制：下一段 NUL 是原路径，一并跳过
				if status:find("[RC]") then
					i = i + 1
				end
				if path ~= "" then
					local abs = top and (top .. "/" .. path) or path
					set[file_utils.normalize_path(abs)] = true
				end
			end
			i = i + 1
		end
	end

	return cache_set(key, set)
end

--- 解析 `--format=%H%x1f%an%x1f%ad%x1f%B%x1e` 的输出为 GitCommit[]（统一「旧 → 新」）。
---@param stdout string|nil
---@return GitCommit[]
local function parse_commits(stdout)
	local commits = {}
	if not stdout or stdout == "" then
		return commits
	end
	local RS = string.char(30)
	local US = string.char(31)
	local field = "^(.-)" .. US .. "(.-)" .. US .. "(.-)" .. US .. "(.*)$"
	for record in stdout:gmatch("(.-)" .. RS) do
		record = record:gsub("^%s+", "")
		local sha, author, date, message = record:match(field)
		if sha and sha ~= "" then
			commits[#commits + 1] = {
				sha = sha,
				short = sha:sub(1, 7),
				author = author,
				date = tonumber(date) or 0,
				message = (message:gsub("%s+$", "")),
			}
		end
	end
	-- git 输出为「新 → 旧」，统一反转为「旧 → 新」，便于状态按时间顺序演进
	local ordered = {}
	for i = #commits, 1, -1 do
		ordered[#ordered + 1] = commits[i]
	end
	return ordered
end

--- 读取提交列表（统一返回「旧 → 新」排序）。
---@param revrange? string 形如 "sha..HEAD"；nil 表示从 HEAD 往前
---@param limit? integer 最多返回多少条
---@param cwd? string
---@param pathspec? string 只取触及该路径的提交
---@return GitCommit[]
function M.log(revrange, limit, cwd, pathspec)
	local key = table.concat({ "log", revrange or "", tostring(limit or 0), cwd or "", pathspec or "" }, "|")
	local value, hit = cache_get(key)
	if hit then
		return value
	end

	-- 用 ASCII 记录/字段分隔符承载完整提交消息，避免多行内容破坏解析
	local args = { "log", "--no-merges", "--date=unix", "--format=%H%x1f%an%x1f%ad%x1f%B%x1e" }
	if limit and limit > 0 then
		args[#args + 1] = "-n"
		args[#args + 1] = tostring(limit)
	end
	if revrange and revrange ~= "" then
		args[#args + 1] = revrange
	end
	if pathspec then
		args[#args + 1] = "--"
		args[#args + 1] = pathspec
	end

	local res = M.exec(args, cwd)
	return cache_set(key, parse_commits(res and res.code == 0 and res.stdout or nil))
end

--- 读取「跟随某段代码」的提交列表（git log -L），返回「旧 → 新」排序。
---@param path string 文件路径（相对仓库或绝对）
---@param start_line integer 起始行（1-based，含）
---@param end_line integer 结束行（含）
---@param cwd? string
---@return GitCommit[]
function M.blame(path, start_line, end_line, cwd)
	start_line = math.max(1, math.floor(tonumber(start_line) or 1))
	end_line = math.max(start_line, math.floor(tonumber(end_line) or start_line))
	local key = table.concat({ "blame", path, tostring(start_line), tostring(end_line), cwd or "" }, "|")
	local value, hit = cache_get(key)
	if hit then
		return value
	end

	local res = M.exec({
		"log", "--no-merges", "--no-patch", "--date=unix",
		"--format=%H%x1f%an%x1f%ad%x1f%B%x1e",
		"-L", ("%d,%d:%s"):format(start_line, end_line, path),
	}, cwd)
	local commits = (res and res.code == 0) and parse_commits(res.stdout) or {}
	return cache_set(key, commits)
end

--- 按完整 / 短 hash 读取单个提交。
---@param sha string
---@param cwd? string
---@return GitCommit|nil
function M.commit(sha, cwd)
	if type(sha) ~= "string" or sha == "" then
		return nil
	end
	local res = M.exec({ "log", "-1", "--date=unix", "--format=%H%x1f%an%x1f%ad%x1f%B%x1e", sha }, cwd)
	if not res or res.code ~= 0 then
		return nil
	end
	return parse_commits(res.stdout)[1]
end

--- 取某提交的完整展示文本（git show）。
---@param sha string
---@param cwd? string
---@return string|nil
function M.show(sha, cwd)
	if type(sha) ~= "string" or sha == "" then
		return nil
	end
	local res = M.exec({ "show", "--stat", "--patch", sha }, cwd)
	if not res or res.code ~= 0 then
		return nil
	end
	local out = (res.stdout or ""):gsub("%s+$", "")
	return out ~= "" and out or nil
end

--- 把任务 git 元数据格式化为紧凑文本（供查看器 / 抽屉展示）。
---@param meta table|nil
---@return string 形如 " ✓ git:1a2b3c4@main@alice"；无元数据返回 ""
function M.format_meta(meta)
	if not meta or type(meta.commit) ~= "string" or meta.commit == "" then
		return ""
	end
	local parts = { "git:" .. meta.commit:sub(1, 7) }
	if meta.branch and meta.branch ~= "" and meta.branch ~= "HEAD" then
		parts[#parts + 1] = meta.branch
	end
	if meta.author and meta.author ~= "" then
		parts[#parts + 1] = meta.author
	end
	local prefix = meta.completed and " ✓ " or " • "
	-- 前缀自带空格，前缀与文本之间无需再加分隔
	return prefix .. table.concat(parts, "@")
end

--- 把锚点失效的 git 归因格式化为提示文本（供查看器 / 抽屉展示）。
---@param meta table|nil
---@return string 形如 " ⚠ 锚点已过期（1a2b3c4 by alice）"；无数据返回 ""
function M.format_anchor_git(meta)
	if not meta or type(meta.sha) ~= "string" or meta.sha == "" then
		return ""
	end
	local who = (meta.author and meta.author ~= "") and (" by " .. meta.author) or ""
	local label = meta.lost and "锚点已丢失" or "锚点已过期"
	return " ⚠ " .. label .. "（" .. meta.sha:sub(1, 7) .. who .. "）"
end

return M
