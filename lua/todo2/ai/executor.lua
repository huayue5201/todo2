-- lua/todo2/ai/executor.lua
-- 支持 full / patch / diff 的 AI 执行器（使用独立模板模块 + 基础 prompt）
local M = {}

local link = require("todo2.store.link")
local prompt = require("todo2.ai.prompt")
local templates = require("todo2.ai.templates")
local ai = require("todo2.ai")
local apply = require("todo2.ai.apply")
local comment = require("todo2.utils.comment")
local vim = vim

-- 简单缓存（文件）
local cache = { data = {}, stats = { hits = 0, misses = 0, saved_tokens = 0 } }
local CACHE_FILE = vim.fn.stdpath("cache") .. "/todo2_ai_cache.json"
local function load_cache()
	local f = io.open(CACHE_FILE, "r")
	if f then
		local c = f:read("*all")
		f:close()
		local ok, d = pcall(vim.fn.json_decode, c)
		if ok and type(d) == "table" then
			cache.data = d
		end
	end
end
local function save_cache()
	local f = io.open(CACHE_FILE, "w")
	if f then
		f:write(vim.fn.json_encode(cache.data))
		f:close()
	end
end
load_cache()

local function gen_cache_key(s)
	return (s or ""):gsub("%s+", " "):gsub("[%p%c]", ""):sub(1, 80):lower()
end

local function find_in_cache(content, threshold)
	threshold = threshold or 0.85
	local key = gen_cache_key(content)
	if cache.data[key] then
		cache.stats.hits = cache.stats.hits + 1
		return cache.data[key]
	end
	-- 简单模糊匹配
	local best, best_score = nil, 0
	local function norm(x)
		return (x or ""):gsub("%s+", " "):gsub("[%p%c]", ""):lower()
	end
	local a = norm(content)
	for k, v in pairs(cache.data) do
		local b = norm(v.content or "")
		if a == b then
			best, best_score = v, 1
			break
		end
		local seen = {}
		for w in a:gmatch("%w+") do
			seen[w] = (seen[w] or 0) + 1
		end
		local common, total = 0, 0
		for w in b:gmatch("%w+") do
			if seen[w] and seen[w] > 0 then
				common = common + 1
				seen[w] = seen[w] - 1
			end
			total = total + 1
		end
		total = total + 1
		local score = common / total
		if score > best_score then
			best, best_score = v, score
		end
	end
	if best and best_score >= threshold then
		cache.stats.hits = cache.stats.hits + 1
		cache.stats.saved_tokens = cache.stats.saved_tokens + (best.tokens or 100)
		return best
	end
	cache.stats.misses = cache.stats.misses + 1
	return nil
end

local function add_to_cache(content, code, tokens)
	local key = gen_cache_key(content)
	cache.data[key] =
		{ content = content, code = code, tokens = tokens or math.ceil(#(code or "") / 4), time = os.time() }
	save_cache()
end

-- 成本控制（简化）
local cost = { daily = 0, total = 0, budget = 10000 }
local COST_FILE = vim.fn.stdpath("cache") .. "/todo2_ai_cost.json"
local function load_cost()
	local f = io.open(COST_FILE, "r")
	if f then
		local c = f:read("*all")
		f:close()
		local ok, d = pcall(vim.fn.json_decode, c)
		if ok and type(d) == "table" then
			if d.date == os.date("%Y-%m-%d") then
				cost.daily = d.daily or 0
			else
				cost.daily = 0
			end
			cost.total = d.total or 0
		end
	end
end
local function save_cost()
	local f = io.open(COST_FILE, "w")
	if f then
		f:write(vim.fn.json_encode({ date = os.date("%Y-%m-%d"), daily = cost.daily, total = cost.total }))
		f:close()
	end
end
load_cost()
local function estimate_tokens(text)
	return math.ceil((text and #text or 0) / 4)
end
local function record_tokens(n)
	cost.daily = cost.daily + (n or 0)
	cost.total = cost.total + (n or 0)
	save_cost()
end
local function check_budget(estimated)
	if cost.daily + estimated > cost.budget then
		local choice = vim.fn.confirm("今日预算可能不足，是否继续？", "&Yes\n&No")
		return choice == 1
	end
	return true
end

-- 读取 CODE 区域（返回 region 或 nil）
local function read_code_region(id)
	local code_link = link.get_code(id, { force_relocate = true })
	if not code_link or not code_link.path or not code_link.line then
		return nil
	end
	local path = code_link.path
	local code_line = code_link.line
	local prefix = comment.get_prefix_by_path(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines then
		return nil
	end
	local end_line = nil
	for i = code_line + 1, #lines do
		local pat = "^%s*" .. vim.pesc(prefix) .. "%s*END:" .. id
		if lines[i]:match(pat) then
			end_line = i
			break
		end
	end
	if not end_line then
		return nil
	end
	local region = {}
	for i = code_line + 1, end_line - 1 do
		table.insert(region, lines[i])
	end
	return { path = path, start = code_line + 1, finish = end_line - 1, lines = region }
end

-- 构造最终 prompt：优先模板（full 模式），否则基础 prompt
local function build_final_prompt(todo, mode, region)
	if mode == "full" then
		local tname = templates.detect(todo.content)
		if tname then
			local tp = templates.build_prompt(todo, tname)
			if tp and tp ~= "" then
				return tp, tname
			end
		end
		return prompt.build_full(todo), nil
	else
		-- patch / diff 使用 contextual prompt（模板不适合局部 diff）
		return prompt.build_contextual(todo, region and table.concat(region.lines, "\n") or ""), nil
	end
end

--- 执行 AI 任务
--- opts: { mode = "full"|"patch"|"diff", use_cache = boolean, use_template = boolean, force = boolean }
function M.execute(id, opts)
	opts = opts or {}
	local mode = opts.mode or "full"

	-- 1. 获取任务
	local todo = link.get_todo(id, { force_relocate = true })
	if not todo then
		return { ok = false, error = "任务不存在" }
	end
	if not todo.ai_executable and not opts.force then
		return { ok = false, error = "任务未标记为 AI 可执行" }
	end

	-- 2. 尝试缓存
	local code = nil
	if opts.use_cache ~= false then
		local cached = find_in_cache(todo.content, 0.85)
		if cached then
			code = cached.code
			vim.notify("✅ 使用缓存结果", vim.log.levels.INFO)
		end
	end

	-- 3. 若需要 region（patch/diff），读取
	local region = nil
	if mode ~= "full" then
		region = read_code_region(id)
	end

	-- 4. 构造 prompt（优先模板）
	local final_prompt, used_template = build_final_prompt(todo, mode, region)

	-- 5. 估算 token 并检查预算
	local est = estimate_tokens(final_prompt) + (mode == "full" and 200 or 80)
	if not check_budget(est) then
		return { ok = false, error = "预算不足" }
	end

	-- 6. 调用 AI（若未命中缓存）
	if not code then
		local out = ai.generate(final_prompt)
		if not out or out == "" then
			return { ok = false, error = "AI 未生成内容" }
		end
		code = out
		record_tokens(est)
		add_to_cache(todo.content, code, est)
	end

	-- 7. 写回（传递 mode，并启用 spinner）
	local ok, err = apply.write_code(id, code, { mode = mode, with_spinner = true })
	if not ok then
		return { ok = false, error = err }
	end

	return { ok = true, code = code, mode = mode, template = used_template }
end

-- 工具：清缓存 / 显示统计
function M.clear_cache()
	cache.data = {}
	cache.stats = { hits = 0, misses = 0, saved_tokens = 0 }
	save_cache()
	vim.notify("AI 缓存已清除", vim.log.levels.INFO)
end

function M.show_stats()
	local total = vim.tbl_count(cache.data)
	local hits = cache.stats.hits
	local misses = cache.stats.misses
	local msg = string.format(
		"AI 缓存：条目=%d, 命中=%d, 未命中=%d, 节省 tokens=%d",
		total,
		hits,
		misses,
		cache.stats.saved_tokens
	)
	vim.notify(msg, vim.log.levels.INFO)
end

return M
