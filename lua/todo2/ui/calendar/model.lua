-- lua/todo2/ui/calendar/model.lua
--- 月历的纯日期计算（无 buffer、无 UI、无任务知识）
---
--- 约定：日期一律用表 { year, month, day }，内部换算走「当天正午」的时间戳，
--- 避免 DST 把日期抖到前一天（与 utils/due.lua 同一策略）。

local M = {}

local DAY = 86400

--- 月份中首个可能的星期序号：1 = 周日，2 = 周一
---@param value string|nil "sunday" | "monday"
---@return integer
function M.week_start(value)
	if value == "sunday" then
		return 1
	end
	return 2
end

---@param year integer
---@param month integer
---@param day integer
---@return number
local function noon(year, month, day)
	return os.time({ year = year, month = month, day = day, hour = 12 })
end

---@return table { year, month, day }
function M.today()
	local t = os.date("*t")
	return { year = t.year, month = t.month, day = t.day }
end

---当前月天数（day = 0 表示「下个月的第 0 天」，即本月最后一天）
---@param year integer
---@param month integer
---@return integer
function M.days_in_month(year, month)
	return tonumber(os.date("%d", os.time({ year = year, month = month + 1, day = 0, hour = 12 })))
end

---星期序号：1 = 周日 … 7 = 周六
---@return integer
function M.weekday(year, month, day)
	return tonumber(os.date("%w", noon(year, month, day))) + 1
end

---日期加减天数，自动跨月跨年
---@return table { year, month, day }
function M.add_days(date, n)
	local t = os.date("*t", noon(date.year, date.month, date.day) + (tonumber(n) or 0) * DAY)
	return { year = t.year, month = t.month, day = t.day }
end

---两个日期相差的天数（a - b）
---@return integer
function M.diff_days(a, b)
	return math.floor((noon(a.year, a.month, a.day) - noon(b.year, b.month, b.day)) / DAY + 0.5)
end

---@param a table
---@param b table
---@return boolean
function M.same_day(a, b)
	return a and b and a.year == b.year and a.month == b.month and a.day == b.day
end

---月份网格：固定 6 行 × 7 列（调用方可裁掉整周都在月外的尾部行，见 view.build_month_lines），两端用相邻月日期补齐
---
---返回的每个单元格都是 `{ year, month, day, in_month }`：
---`in_month = false` 表示本月之外的补位日（渲染时变暗，但可点击/可跳转）。
---@param year integer
---@param month integer
---@param opts? { first_day_of_week?: string }
---@return table[][] weeks
function M.grid(year, month, opts)
	opts = opts or {}
	local week_start = M.week_start(opts.first_day_of_week)
	local offset = (M.weekday(year, month, 1) - week_start) % 7
	local start = noon(year, month, 1) - offset * DAY

	local weeks = {}
	local idx = 0
	for row = 1, 6 do
		local week = {}
		for col = 1, 7 do
			local t = os.date("*t", start + idx * DAY)
			idx = idx + 1
			week[col] = {
				year = t.year,
				month = t.month,
				day = t.day,
				in_month = (t.year == year and t.month == month),
			}
		end
		weeks[row] = week
	end
	return weeks
end

---解析 `YYYY-MM`（:TodoCalendar 参数），非法时返回 nil
---@param text string|nil
---@return table|nil { year, month }
function M.parse_month(text)
	local y, m = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	y, m = tonumber(y), tonumber(m)
	if m < 1 or m > 12 then
		return nil
	end
	return { year = y, month = m }
end

return M
