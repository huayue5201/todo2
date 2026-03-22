-- lua/todo2/core/embedding.lua
-- 增强版：复用 hash 模块

local M = {}
local hash = require("todo2.utils.hash") -- 复用 hash 模块

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local config = {
	enabled = true,
	backend = "mock", -- "mock" | "openai" | "local"
	mock_dim = 64,
	cache_ttl = 3600, -- 缓存1小时
}

-- 后端实现
local backends = {}

---------------------------------------------------------------------
-- Mock 后端（使用 hash 模块，增强版）
---------------------------------------------------------------------
local mock_backend = {
	name = "mock",

	-- 基于 hash 生成向量
	get = function(text)
		local dim = config.mock_dim
		local vec = {}

		-- 初始化向量
		for i = 1, dim do
			vec[i] = 0
		end

		-- 使用多个哈希种子增强分布
		local seeds = { 0x11111111, 0x22222222, 0x33333333, 0x44444444 }
		for _, seed in ipairs(seeds) do
			local h = hash.combine(text, tostring(seed))
			local idx = (tonumber(h, 16) % dim) + 1
			vec[idx] = vec[idx] + 1
		end

		-- 对文本中的单词分别哈希
		for w in text:lower():gmatch("[%w_]+") do
			if #w > 1 then
				local h = hash.hash(w)
				local idx = (tonumber(h, 16) % dim) + 1
				vec[idx] = vec[idx] + 1
			end
		end

		-- 归一化
		local norm = 0
		for i = 1, dim do
			norm = norm + vec[i] * vec[i]
		end
		norm = math.sqrt(norm)
		if norm > 0 then
			for i = 1, dim do
				vec[i] = vec[i] / norm
			end
		end

		return vec
	end,

	similarity = function(vecA, vecB)
		local dot = 0
		local na = 0
		local nb = 0

		for i = 1, math.min(#vecA, #vecB) do
			dot = dot + vecA[i] * vecB[i]
			na = na + vecA[i] * vecA[i]
			nb = nb + vecB[i] * vecB[i]
		end

		if na == 0 or nb == 0 then
			return 0
		end
		return dot / (math.sqrt(na) * math.sqrt(nb))
	end,
}

---------------------------------------------------------------------
-- OpenAI 后端（预留）
---------------------------------------------------------------------
local openai_backend = {
	name = "openai",

	get = function(text)
		-- TODO: 实现 OpenAI API 调用
		-- 使用 hash 模块生成缓存键
		local _ = hash.combine("openai", text) -- 修复 unused 警告
		-- 调用 API...
		return nil
	end,

	similarity = mock_backend.similarity,
}

---------------------------------------------------------------------
-- 本地模型后端（预留）
---------------------------------------------------------------------
local local_backend = {
	name = "local",

	get = function(text)
		-- TODO: 实现本地模型调用
		local _ = hash.combine("local", text) -- 修复 unused 警告
		-- 调用本地模型...
		return nil
	end,

	similarity = mock_backend.similarity,
}

-- 注册后端（只保留一个 mock）
backends.mock = mock_backend
backends.openai = openai_backend
backends.native = local_backend

---------------------------------------------------------------------
-- 缓存（使用 hash 作为键）
---------------------------------------------------------------------
local cache = {}

local function get_cached(text)
	local cache_key = hash.hash(text)
	local entry = cache[cache_key]
	if entry then
		local now = os.time()
		if now - entry.timestamp <= config.cache_ttl then
			return entry.vector
		end
		cache[cache_key] = nil
	end
	return nil
end

local function set_cache(text, vector)
	local cache_key = hash.hash(text)
	cache[cache_key] = {
		vector = vector,
		timestamp = os.time(),
	}
end

---------------------------------------------------------------------
-- 公开接口
---------------------------------------------------------------------

--- 设置配置
--- @param opts table
function M.setup(opts)
	if opts.enabled ~= nil then
		config.enabled = opts.enabled
	end
	if opts.backend then
		if backends[opts.backend] then
			config.backend = opts.backend
		else
			vim.notify("[embedding] 未知后端: " .. opts.backend, vim.log.levels.WARN)
		end
	end
	if opts.mock_dim then
		config.mock_dim = opts.mock_dim
	end
	if opts.cache_ttl then
		config.cache_ttl = opts.cache_ttl
	end
end

--- 是否可用
--- @return boolean
function M.is_available()
	if not config.enabled then
		return false
	end
	local backend = backends[config.backend]
	return backend ~= nil
end

--- 获取向量
--- @param text string
--- @return table|nil
function M.get(text)
	if not config.enabled then
		return nil
	end
	if not text or text == "" then
		return nil
	end

	-- 缓存命中
	local cached = get_cached(text)
	if cached then
		return cached
	end

	local backend = backends[config.backend]
	if not backend then
		return nil
	end

	local vector = backend.get(text)
	if vector then
		set_cache(text, vector)
	end

	return vector
end

--- 计算相似度
--- @param vecA table
--- @param vecB table
--- @return number
function M.similarity(vecA, vecB)
	if not vecA or not vecB then
		return 0
	end

	local backend = backends[config.backend]
	if not backend then
		return 0
	end

	return backend.similarity(vecA, vecB)
end

--- 批量获取向量（优化性能）
--- @param texts table
--- @return table
function M.batch_get(texts)
	if not config.enabled or not texts then
		return {}
	end

	local results = {}
	local to_compute = {}
	local compute_indices = {}

	-- 检查缓存
	for i, text in ipairs(texts) do
		local cached = get_cached(text)
		if cached then
			results[i] = cached
		else
			table.insert(to_compute, text)
			table.insert(compute_indices, i)
		end
	end

	-- 批量计算未缓存的
	if #to_compute > 0 then
		local backend = backends[config.backend]
		if backend and backend.batch_get then
			local computed = backend.batch_get(to_compute)
			for j, vec in ipairs(computed) do
				local idx = compute_indices[j]
				results[idx] = vec
				set_cache(to_compute[j], vec)
			end
		else
			-- 降级到单个计算
			for j, text in ipairs(to_compute) do
				local vec = M.get(text)
				results[compute_indices[j]] = vec
			end
		end
	end

	return results
end

--- 清空缓存
function M.clear_cache()
	cache = {}
end

--- 获取当前后端信息
--- @return table
function M.get_backend_info()
	local count = 0
	for _ in pairs(cache) do
		count = count + 1
	end
	return {
		name = config.backend,
		enabled = config.enabled,
		cache_size = count,
	}
end

--- 测试函数
function M.test()
	local test_texts = {
		"修复函数参数错误",
		"修复返回值类型不匹配",
		"添加错误处理",
		"优化性能",
	}

	print("=== Embedding 测试 ===")
	print("后端:", config.backend)
	print("缓存 TTL:", config.cache_ttl)
	print("向量维度:", config.mock_dim)
	print("")

	local vectors = {}
	for _, text in ipairs(test_texts) do
		local vec = M.get(text)
		vectors[text] = vec
		print("文本:", text)
		if vec then
			local preview = {}
			for i = 1, math.min(5, #vec) do
				table.insert(preview, string.format("%.3f", vec[i]))
			end
			print("  向量前5维:", table.concat(preview, ", "))
		else
			print("  向量: nil")
		end
	end

	print("")
	print("=== 相似度测试 ===")
	for i = 1, #test_texts do
		for j = i + 1, #test_texts do
			local sim = M.similarity(vectors[test_texts[i]], vectors[test_texts[j]])
			print(string.format("'%s' vs '%s': %.3f", test_texts[i], test_texts[j], sim))
		end
	end
end

return M
