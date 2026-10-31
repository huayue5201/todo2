-- lua/todo2/render/progress.lua
local M = {}

local config = require("todo2.config")

--- 根据进度信息构建用于 virt_text 的进度条片段
--- @param progress table { percent, done, total }
--- @return table virt_text 片段
function M.build(progress)
	if not progress or progress.total <= 1 then
		return {}
	end

	local bar_config = M.config()
	local style = bar_config.style or "full"
	local highlights = bar_config.highlights or { done = "Todo2ProgressDone", todo = "Todo2ProgressTodo" }

	local virt = {}

	if style == "full" then
		local bar = M.bar_chunks(progress)
		table.insert(virt, { " ", "Normal" })
		for _, chunk in ipairs(bar) do
			table.insert(virt, chunk)
		end

		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("%d%% (%d/%d)", progress.percent, progress.done, progress.total),
			highlights.done,
		})
	elseif style == "percent" then
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, { string.format("%d%%", progress.percent), highlights.done })
	elseif style == "simple" then
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, { string.format("(%d/%d)", progress.done, progress.total), highlights.done })
	elseif style == "compact" then
		table.insert(virt, { " ", "Normal" })
		table.insert(virt, {
			string.format("%d%% (%d/%d)", progress.percent, progress.done, progress.total),
			highlights.done,
		})
	end

	return virt
end

--- 进度条配置（单一读取点，避免各处各自 `config.get("progress_bar")` 猜默认值）
---@return table
function M.config()
	return config.get("progress_bar") or {}
end

--- 进度条本体（只有字符，不含百分比/计数），按配置字符与 style 生成
---@param progress table { percent, done?, total }
---@return table[] virt_text 片段（style 非 full 时为空）
function M.bar_chunks(progress)
	local bar_config = M.config()
	if (bar_config.style or "full") ~= "full" then
		return {}
	end
	if not progress or not progress.total or progress.total <= 0 then
		return {}
	end
	local chars = bar_config.chars or { filled = "▰", empty = "▱" }
	local len_config = bar_config.length or { min = 5, max = 20 }
	local highlights = bar_config.highlights or { done = "Todo2ProgressDone", todo = "Todo2ProgressTodo" }

	local len = math.max(len_config.min or 5, math.min(len_config.max or 20, progress.total))
	local filled = math.floor((progress.percent or 0) / 100 * len)
	local chunks = {}
	for _ = 1, filled do
		chunks[#chunks + 1] = { chars.filled, highlights.done }
	end
	for _ = filled + 1, len do
		chunks[#chunks + 1] = { chars.empty, highlights.todo }
	end
	return chunks
end

--- 进度条纯文本（浮窗标题 / 状态行复用同一套字符与 style，别再造第二套）
---@param progress table { percent, done?, total }
---@return string 空串表示没有字符条（style 非 full 或 total <= 0）
function M.bar_text(progress)
	local chunks = M.bar_chunks(progress)
	if #chunks == 0 then
		return ""
	end
	local out = {}
	for _, chunk in ipairs(chunks) do
		out[#out + 1] = chunk[1]
	end
	return table.concat(out)
end

return M
