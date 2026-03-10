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

	local bar_config = config.get("progress_bar") or {}
	local style = bar_config.style or "full"
	local chars = bar_config.chars or { filled = "▰", empty = "▱", separator = " " }
	local len_config = bar_config.length or { min = 5, max = 20 }
	local highlights = bar_config.highlights or { done = "Todo2ProgressDone", todo = "Todo2ProgressTodo" }

	local virt = {}

	if style == "full" then
		local len = math.max(len_config.min, math.min(len_config.max, progress.total))
		local filled = math.floor(progress.percent / 100 * len)

		table.insert(virt, { " ", "Normal" })

		for _ = 1, filled do
			table.insert(virt, { chars.filled, highlights.done })
		end

		for _ = filled + 1, len do
			table.insert(virt, { chars.empty, highlights.todo })
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

return M
