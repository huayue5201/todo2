-- lua/todo2/render/filter.lua
-- 编辑器内的标签筛选：只显示命中 `#tag` 的任务（连同其祖先与后代），其余行整行隐藏。
--
-- 隐藏通过 extmark 的 conceal_lines = "" 实现（Neovim 0.11+ 支持），
-- 需要窗口 conceallevel >= 2 —— TODO 文件默认已由 conceal 模块设置为 2。
--
-- 可见性规则：
--   * 任务命中筛选标签（要求包含全部筛选标签）；
--   * 或某个祖先命中（保持子树完整）；
--   * 或某个后代命中（保留父级上下文）。
--   * 非任务行（描述续行/空行）沿用上方最近任务行的可见性。

local M = {}

local constants = require("todo2.constants")
local format = require("todo2.utils.format")
local tags_utils = require("todo2.utils.tags")
local core = require("todo2.store.task.core")
local git = require("todo2.integrations.git")

local NS = constants.ns("filter")

--- 每个缓冲区当前激活的筛选标签（nil 表示未筛选）。
---@type table<number, string[]>
local state = {}

--- 返回缓冲区的筛选标签；未筛选返回 nil。
---@param bufnr number
---@return string[]|nil
function M.active(bufnr)
	return state[bufnr]
end

--- 缓冲区是否开启了筛选。
---@param bufnr number
---@return boolean
function M.is_active(bufnr)
	return state[bufnr] ~= nil
end

--- 清除筛选（含已绘制的隐藏标记）。
---@param bufnr number
function M.clear(bufnr)
	state[bufnr] = nil
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

---------------------------------------------------------------------
-- 可见性计算
---------------------------------------------------------------------

--- git 派生伪标签前缀（如 #git:dirty / #git:branch:main）。
local GIT_PREFIX = "git:"

--- 单个筛选词是否命中任务行（普通 #tag 或 git 派生伪标签）。
---@param parsed table parse_task_line 结果
---@param tag string
---@param ctx table 预计算的 git 上下文
---@return boolean
local function match_tag(parsed, tag, ctx)
	if tag == GIT_PREFIX .. "dirty" then
		local task = parsed.id and core.get_task(parsed.id)
		local loc = task and task.locations and task.locations.code
		return loc ~= nil and ctx.dirty ~= nil and ctx.dirty[loc.path] == true
	end
	if tag:sub(1, #GIT_PREFIX + 7) == GIT_PREFIX .. "branch:" then
		local task = parsed.id and core.get_task(parsed.id)
		return task ~= nil and task.git ~= nil and task.git.branch == tag:sub(#GIT_PREFIX + 8)
	end
	return tags_utils.contains(parsed.tags, tag)
end

--- 行是否命中全部筛选标签（AND）。
---@param parsed table
---@param want string[]
---@param ctx table
---@return boolean
local function matches(parsed, want, ctx)
	for _, tag in ipairs(want) do
		if not match_tag(parsed, tag, ctx) then
			return false
		end
	end
	return true
end

--- 预计算 git 伪标签所需的上下文（仅在用到时才调用 git）。
---@param want string[]
---@return table
local function build_git_context(want)
	local ctx = {}
	for _, tag in ipairs(want) do
		if tag == GIT_PREFIX .. "dirty" then
			ctx.dirty = git.dirty_files()
		end
	end
	return ctx
end

--- 计算每一行的可见性。
---@param lines string[]
---@param want string[]
---@return boolean[]
local function compute_visibility(lines, want)
	local n = #lines
	local ctx = build_git_context(want)
	---@type table<number, { level: number, match: boolean, vis: boolean }>
	local info = {}
	for i = 1, n do
		local parsed = format.parse_task_line(lines[i])
		if parsed then
			info[i] = { level = parsed.level, match = matches(parsed, want, ctx), vis = false }
		end
	end

	-- 自顶向下：自身命中或任一祖先命中 → 可见
	local stack = {}
	for i = 1, n do
		local it = info[i]
		if it then
			while #stack > 0 and stack[#stack].level >= it.level do
				table.remove(stack)
			end
			local parent_vis = #stack > 0 and stack[#stack].vis or false
			it.vis = it.match or parent_vis
			stack[#stack + 1] = { level = it.level, vis = it.vis }
		end
	end

	-- 自底向上：任一后代命中 → 祖先可见
	local stack2 = {}
	for i = 1, n do
		local it = info[i]
		if it then
			while #stack2 > 0 and stack2[#stack2].level >= it.level do
				table.remove(stack2)
			end
			if it.match then
				for _, anc in ipairs(stack2) do
					anc.vis = true
				end
			end
			stack2[#stack2 + 1] = it
		end
	end

	-- 汇总：非任务行沿用上方最近任务行的可见性
	local visible = {}
	local current = true
	for i = 1, n do
		local it = info[i]
		if it then
			current = it.vis
		end
		visible[i] = current
	end
	return visible
end

---------------------------------------------------------------------
-- 应用
---------------------------------------------------------------------

--- 按当前筛选标签重新计算并隐藏不匹配的行。
---@param bufnr number
function M.refresh(bufnr)
	local want = state[bufnr]
	if not want then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		state[bufnr] = nil
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local visible = compute_visibility(lines, want)
	for i = 1, #lines do
		if not visible[i] then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, i - 1, 0, {
				end_row = i - 1,
				end_col = #lines[i],
				conceal_lines = "",
			})
		end
	end

	-- 确保窗口启用了 conceal：buffer 可能是在未显示时就被渲染的
	-- （此时 conceallevel 仍为 0），这样隐藏标记才会真正生效。
	pcall(function()
		require("todo2.render.conceal").setup_window_conceal(bufnr)
	end)
end

--- 设置并立即应用筛选；空标签等价于清除。
---@param bufnr number
---@param tags string[]
function M.set(bufnr, tags)
	-- 普通标签归一化（小写去重排序）；git 伪标签保留原样，以保持分支名大小写
	local plain, pseudo = {}, {}
	for _, tag in ipairs(tags or {}) do
		local s = tostring(tag):gsub("^#", "")
		if s ~= "" then
			if s:sub(1, #GIT_PREFIX) == GIT_PREFIX then
				pseudo[#pseudo + 1] = s
			else
				plain[#plain + 1] = s
			end
		end
	end

	local want = tags_utils.normalize(plain)
	vim.list_extend(want, pseudo)
	if #want == 0 then
		M.clear(bufnr)
		return
	end
	state[bufnr] = want
	M.refresh(bufnr)
end

return M
