-- lua/todo2/ai/git.lua
-- Git 操作模块：检查点、回滚、状态检测

local M = {}

local uv = vim.loop or vim.uv

---执行 git 命令
---@param args table 命令参数
---@param cwd string|nil 工作目录
---@param timeout_ms integer 超时毫秒
---@return string|nil output
---@return integer code
local function git_run(args, cwd, timeout_ms)
	timeout_ms = timeout_ms or 5000
	cwd = cwd or vim.fn.getcwd()

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local done = false
	local exit_code = nil

	local handle = uv.spawn("git", {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = cwd,
	}, function(code)
		exit_code = code
		stdout:close()
		stderr:close()
		handle:close()
		done = true
	end)

	if not handle then
		return nil, -1
	end

	stdout:read_start(function(err, data)
		if data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)

	stderr:read_start(function(err, data)
		if data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)

	-- 等待完成
	local start = uv.hrtime() / 1e6
	while not done do
		if (uv.hrtime() / 1e6) - start > timeout_ms then
			handle:kill("sigterm")
			return nil, -1
		end
		vim.wait(10)
	end

	local output = table.concat(stdout_chunks) .. table.concat(stderr_chunks)
	return output, exit_code or 0
end

---检查是否为 git 仓库
---@param path string|nil 路径
---@return boolean
function M.is_repo(path)
	local out, code = git_run({ "rev-parse", "--git-dir" }, path, 2000)
	return code == 0
end

---获取当前 HEAD SHA
---@param path string|nil
---@return string|nil
function M.head_sha(path)
	local out, code = git_run({ "rev-parse", "HEAD" }, path, 2000)
	if code == 0 and out then
		return vim.trim(out)
	end
	return nil
end

---检查工作区是否干净
---@param path string|nil
---@return boolean is_clean
---@return string|nil changes
function M.is_clean(path)
	local out, code = git_run({ "status", "--porcelain" }, path, 3000)
	if code ~= 0 then
		return true, nil
	end
	local changes = vim.trim(out or "")
	return changes == "", changes
end

---创建检查点
---@param message string 提交消息
---@param path string|nil 工作目录
---@return string|nil sha 提交 SHA，失败返回 nil
---@return string|nil error
function M.checkpoint(message, path)
	-- 检查是否有变更
	local is_clean, changes = M.is_clean(path)
	if is_clean then
		return nil, "no changes"
	end

	-- 添加所有变更
	local _, add_code = git_run({ "add", "-A" }, path, 5000)
	if add_code ~= 0 then
		return nil, "git add failed"
	end

	-- 提交
	local _, commit_code = git_run({ "commit", "-m", message, "--no-verify" }, path, 10000)
	if commit_code ~= 0 then
		return nil, "git commit failed"
	end

	-- 返回新提交的 SHA
	return M.head_sha(path), nil
end

---回滚到指定 SHA
---@param sha string 目标 SHA
---@param path string|nil
---@return boolean success
---@return string|nil error
function M.rollback(sha, path)
	if not sha then
		return false, "no target SHA"
	end

	local _, code = git_run({ "reset", "--hard", sha }, path, 5000)
	if code ~= 0 then
		return false, "git reset failed"
	end

	-- 清理未跟踪文件
	git_run({ "clean", "-fd" }, path, 5000)

	return true, nil
end

---回滚到上一个检查点（HEAD~1）
---@param path string|nil
---@return boolean success
---@return string|nil error
function M.rollback_last(path)
	local current = M.head_sha(path)
	if not current then
		return false, "no HEAD"
	end

	local _, code = git_run({ "reset", "--hard", "HEAD~1" }, path, 5000)
	if code ~= 0 then
		return false, "git reset failed"
	end

	-- 清理未跟踪文件
	git_run({ "clean", "-fd" }, path, 5000)

	return true, nil
end

---保存当前状态（不提交，仅记录 SHA）
---@param path string|nil
---@return string|nil sha
function M.save_state(path)
	local sha = M.head_sha(path)
	if sha then
		return sha
	end
	return nil
end

---恢复到保存的状态
---@param sha string
---@param path string|nil
---@return boolean success
function M.restore_state(sha, path)
	if not sha then
		return false
	end
	return M.rollback(sha, path)
end

---生成智能提交消息
---@param task_title string 任务标题
---@param task_type string 任务类型 (bug_fix, feature, refactor, etc.)
---@return string
function M.smart_message(task_title, task_type)
	local prefixes = {
		bug_fix = "fix",
		feature = "feat",
		refactor = "refactor",
		documentation = "docs",
		testing = "test",
		performance = "perf",
		cleanup = "chore",
	}

	local prefix = prefixes[task_type] or "feat"
	local message = string.format("%s: %s", prefix, task_title:sub(1, 60))

	-- 移除可能的多余换行
	message = message:gsub("\n", " "):gsub("%s+", " ")

	return message
end

---获取最近 N 次提交
---@param n integer
---@param path string|nil
---@return table[] { hash, message }
function M.last_commits(n, path)
	n = n or 10
	local out, code = git_run({ "log", "--oneline", "-" .. n, "--format=%H %s" }, path, 5000)
	if code ~= 0 or not out then
		return {}
	end

	local commits = {}
	for line in out:gmatch("[^\n]+") do
		local hash, message = line:match("^(%S+)%s+(.+)$")
		if hash then
			commits[#commits + 1] = {
				hash = hash,
				message = message,
				short_hash = hash:sub(1, 7),
			}
		end
	end
	return commits
end

return M
