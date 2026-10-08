-- lua/todo2/handlers/git.lua
-- git ⇄ 任务 的闭环：
--   :TodoGitSync   从「上次同步的提交」增量扫描到 HEAD，把提交消息里的任务引用落成状态 + 元数据
--   :TodoGitReview 列出代码锚点落在 git 脏文件中的任务（提交前自查）

local M = {}

local git = require("todo2.integrations.git")
local config = require("todo2.config")
local core = require("todo2.store.task.core")
local status_domain = require("todo2.core.status")
local types = require("todo2.store.types")
local events = require("todo2.core.events")
local store = require("todo2.store.nvim_store")
local query = require("todo2.store.task.query")
local tags_utils = require("todo2.utils.tags")

local CURSOR_KEY = "git_last_synced_commit"
local MAX_COMMITS = 200

--- 把用户配置的 refs 规则编译为 { pattern, status } 列表。
---@return table[]
local function rules()
	local out = {}
	for _, rule in ipairs(config.get("git.refs") or {}) do
		if type(rule) == "table" and type(rule.pattern) == "string" and type(rule.status) == "string" then
			out[#out + 1] = { pattern = rule.pattern, status = rule.status }
		end
	end
	return out
end

--- 在提交消息里提取所有匹配的任务 id。
---@param message string
---@param pattern string
---@return string[]
local function extract_ids(message, pattern)
	local ids = {}
	for id in message:gmatch(pattern) do
		if id ~= "" then
			ids[#ids + 1] = id
		end
	end
	return ids
end

--- 把一条引用落成状态与 git 元数据；目标状态未知或任务不存在时静默跳过。
--- commit.sha 为空（手动按消息匹配）时只改状态，不动已有 git 元数据。
---@param id string
---@param target string
---@param commit GitCommit
---@param branch? string
---@return boolean
local function apply_ref(id, target, commit, branch)
	if not core.get_task(id) or not status_domain.get_definition(target) then
		return false
	end
	status_domain.set_status(id, target, "git", { skip_event = true })
	if commit and type(commit.sha) == "string" and commit.sha ~= "" then
		core.set_git(id, {
			commit = commit.sha,
			branch = branch,
			author = commit.author,
			completed = types.is_completed_status(target) or nil,
		})
	end
	return true
end

--- 把一条提交消息里的所有任务引用依次落成状态与元数据。
---@param message string
---@param commit GitCommit
---@param branch? string
---@param compiled table[] 已编译的 refs 规则
---@return string[] 实际更新的任务 id（去重、保序）
local function apply_message(message, commit, branch, compiled)
	if type(message) ~= "string" or message == "" then
		return {}
	end
	local changed, seen = {}, {}
	for _, rule in ipairs(compiled) do
		for _, id in ipairs(extract_ids(message, rule.pattern)) do
			-- 同一消息内按规则顺序应用，最新一次引用覆盖较早的
			if apply_ref(id, rule.status, commit, branch) and not seen[id] then
				seen[id] = true
				changed[#changed + 1] = id
			end
		end
	end
	return changed
end

--- 增量同步：把「上次同步提交..HEAD」内的任务引用应用到 store。
---@param opts? { force?: boolean, silent?: boolean }
---@return { scanned: integer, changed: integer }
function M.sync(opts)
	opts = opts or {}
	local cfg = config.get("git") or {}

	if not cfg.enable and not opts.force then
		if not opts.silent then
			vim.notify("[todo2] git integration is disabled (config.git.enable = true)", vim.log.levels.WARN)
		end
		return { scanned = 0, changed = 0 }
	end
	if not git.available() then
		if not opts.silent then
			vim.notify("[todo2] Current directory is not a git repository", vim.log.levels.WARN)
		end
		return { scanned = 0, changed = 0 }
	end

	local head = git.head()
	if not head then
		return { scanned = 0, changed = 0 }
	end

	local last = store.get_key(CURSOR_KEY)
	if type(last) ~= "string" or last == "" then
		store.set_key(CURSOR_KEY, head)
		if not opts.silent then
			vim.notify("[todo2] Git sync baseline established; only later commits will be scanned", vim.log.levels.INFO)
		end
		return { scanned = 0, changed = 0 }
	end
	if last == head then
		if not opts.silent then
			vim.notify("[todo2] Up to date (no new commits)", vim.log.levels.INFO)
		end
		return { scanned = 0, changed = 0 }
	end

	-- 游标被改写 / 历史被重写时 is_ancestor 为假，退化为扫描最近贡献
	local revrange = git.is_ancestor(last, head) and (last .. ".." .. head) or nil
	local commits = git.log(revrange, MAX_COMMITS)
	local branch = git.branch()
	local compiled = rules()

	local changed_ids, changed_set = {}, {}
	for _, commit in ipairs(commits) do
		-- 旧 → 新依次应用，最新一次引用决定最终状态与元数据
		for _, id in ipairs(apply_message(commit.message, commit, branch, compiled)) do
			if not changed_set[id] then
				changed_set[id] = true
				changed_ids[#changed_ids + 1] = id
			end
		end
	end

	store.set_key(CURSOR_KEY, head)
	if #changed_ids > 0 then
		events.emit("git_sync", { changed_ids = changed_ids, ids = changed_ids, files = {} })
	end

	if not opts.silent then
		vim.notify(
			("[todo2] git sync: scanned %d commits, updated %d tasks"):format(#commits, #changed_ids),
			vim.log.levels.INFO
		)
	end
	return { scanned = #commits, changed = #changed_ids }
end

--- 提交前自查：列出代码锚点落在 git 脏文件里的任务。
function M.review()
	if not git.available() then
		vim.notify("[todo2] Current directory is not a git repository", vim.log.levels.WARN)
		return
	end

	local dirty = git.dirty_files()
	local items = {}
	for path in pairs(dirty) do
		local found = query.find_by_file(path)
		for _, task in pairs(found.code or {}) do
			local loc = task.locations and task.locations.code
			if loc and loc.line and loc.line > 0 then
				local text = task.core.content or ""
				if task.core.tags and #task.core.tags > 0 then
					text = text .. tags_utils.format(task.core.tags)
				end
				items[#items + 1] = { filename = path, lnum = loc.line, text = text }
			end
		end
	end

	if #items == 0 then
		vim.notify("[todo2] No task anchors in dirty files", vim.log.levels.INFO)
		return
	end

	table.sort(items, function(a, b)
		if a.filename == b.filename then
			return a.lnum < b.lnum
		end
		return a.filename < b.filename
	end)

	vim.fn.setqflist(items, "r")
	vim.cmd("copen")
end

--- 把某一提交（或一段消息）里的任务引用落成状态；供 MCP 显式调用，不受 git.enable 限制。
---@param opts { sha?: string, message?: string }
---@return { changed: integer }|nil, string|nil
function M.complete_by_commit(opts)
	opts = opts or {}
	if not git.available() then
		return nil, "Current directory is not a git repository"
	end

	local commit, message
	if type(opts.sha) == "string" and opts.sha ~= "" then
		commit = git.commit(opts.sha)
		if not commit then
			return nil, "Commit not found: " .. opts.sha
		end
		message = commit.message
	elseif type(opts.message) == "string" and opts.message ~= "" then
		-- 仅有消息、没有提交：可关单，但没有可记录的元数据
		commit = { sha = "", author = nil }
		message = opts.message
	else
		return nil, "Either sha or message is required"
	end

	local changed = apply_message(message, commit, git.branch(), rules())
	if #changed > 0 then
		events.emit("git_sync", { changed_ids = changed, ids = changed, files = {} })
	end
	return { changed = #changed }
end

--- 查看指定任务锚点的 git 历史。
---@param id string
local function blame_id(id)
	local loc = query.resolve_code_location(id)
	if not loc or not loc.path then
		vim.notify("[todo2] task " .. id .. " has no code anchor", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	local lost = task and core.anchor_state(task) == core.ANCHOR.LOST
	local start_line = loc.block_start or loc.line or 1
	local end_line = loc.block_end or start_line
	-- lost 时锚点已不可定位，退化为看文件的最近提交
	local commits = lost and git.log(nil, 30, nil, loc.path) or git.blame(loc.path, start_line, end_line)
	if #commits == 0 then
		vim.notify("[todo2] No related commits found", vim.log.levels.INFO)
		return
	end

	-- git 返回「旧 → 新」，列表展示为「新 → 旧」
	local items, picked = {}, {}
	for i = #commits, 1, -1 do
		local c = commits[i]
		local subject = (c.message or ""):match("^[^\n]*") or ""
		items[#items + 1] = ("%s  %s  %s"):format(c.short, os.date("%Y-%m-%d", c.date), subject)
		picked[#picked + 1] = c
	end

	local range = (loc.block_end and loc.block_end ~= start_line) and (start_line .. "-" .. end_line) or tostring(start_line)
	vim.ui.select(items, { prompt = "git history (anchor " .. range .. "):" }, function(_, idx)
		if not idx then
			return
		end
		local text = git.show(picked[idx].sha)
		if not text then
			vim.notify("[todo2] cannot read commit " .. picked[idx].short, vim.log.levels.WARN)
			return
		end
		require("todo2.ui.scratch").open(text, "git")
	end)
end

--- 查看任务代码锚点的 git 历史（:TodoGitBlame）。
---@param id? string 缺省用光标所在任务
function M.blame(id)
	if not git.available() then
		vim.notify("[todo2] Current directory is not a git repository", vim.log.levels.WARN)
		return
	end

	if id and id ~= "" then
		return blame_id(id)
	end

	require("todo2.task.picker").pick({ none_msg = "[todo2] No task at cursor" }, function(task)
		blame_id(task.id)
	end)
end

return M
