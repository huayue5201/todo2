-- lua/todo2/core/embedding.lua
-- 极简 embedding 模块（可随时替换为真实 embedding 后端）

local M = {}

---------------------------------------------------------------------
-- 配置：是否启用 embedding（你可以在 config 中控制）
---------------------------------------------------------------------
local ENABLE = true

---------------------------------------------------------------------
-- 简单缓存：text -> vector
---------------------------------------------------------------------
local cache = {}

---------------------------------------------------------------------
-- 工具：简单 hash（把字符串变成固定长度向量）
-- 这是“伪 embedding”，但足够用于语义图谱的初期实验
---------------------------------------------------------------------
local function simple_hash_embedding(text, dim)
	dim = dim or 64
	local vec = {}

	-- 初始化
	for i = 1, dim do
		vec[i] = 0
	end

	-- 简单 hash：按字符累加
	for i = 1, #text do
		local c = text:byte(i)
		local idx = (c % dim) + 1
		vec[idx] = vec[idx] + 1
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
end

---------------------------------------------------------------------
-- 公开接口：是否可用
---------------------------------------------------------------------
function M.is_available()
	return ENABLE
end

---------------------------------------------------------------------
-- 公开接口：获取 embedding（向量）
-- 未来你可以把这里替换成真实 API 调用
---------------------------------------------------------------------
function M.get(text)
	if not ENABLE then
		return nil
	end
	if not text or text == "" then
		return nil
	end

	-- 缓存
	if cache[text] then
		return cache[text]
	end

	-- 生成伪 embedding
	local vec = simple_hash_embedding(text, 64)
	cache[text] = vec
	return vec
end

---------------------------------------------------------------------
-- 公开接口：计算相似度（余弦相似度）
---------------------------------------------------------------------
function M.similarity(vecA, vecB)
	if not vecA or not vecB then
		return 0
	end

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
end

return M
