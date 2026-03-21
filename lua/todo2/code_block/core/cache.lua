local M = {}

local function now()
	return os.time()
end

---@class CodeBlockCache
---@field ttl integer
---@field max_items integer
---@field store table<string, {timestamp:integer, data:any}>

function M.new(opts)
	local self = {
		ttl = opts.ttl or 60,
		max_items = opts.max_items or 200,
		store = {},
	}

	---@param key string
	---@return any|nil
	function self:get(key)
		local entry = self.store[key]
		if not entry then
			return nil
		end
		if self.ttl > 0 and now() - entry.timestamp > self.ttl then
			self.store[key] = nil
			return nil
		end
		return entry.data
	end

	---@param key string
	---@param data any
	function self:set(key, data)
		self.store[key] = {
			timestamp = now(),
			data = data,
		}
		local count = 0
		for _ in pairs(self.store) do
			count = count + 1
		end
		if count <= self.max_items then
			return
		end
		-- 淘汰最旧
		local oldest_key, oldest_ts
		for k, v in pairs(self.store) do
			if not oldest_ts or v.timestamp < oldest_ts then
				oldest_ts = v.timestamp
				oldest_key = k
			end
		end
		if oldest_key then
			self.store[oldest_key] = nil
		end
	end

	function self:clear(prefix)
		if not prefix then
			self.store = {}
			return
		end
		for k in pairs(self.store) do
			if k:match("^" .. prefix) then
				self.store[k] = nil
			end
		end
	end

	return self
end

return M
