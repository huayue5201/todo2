-- lua/todo2/utils/due.lua
-- 到期日（due）：只有日期、没有时间的纯业务字段。
--
-- 文件语法（紧跟 `<status>:<id>` 标记之后、标签段之前）：
--     - [ ] todo:ab12cd @2026-07-01 #fix 修登录
--
-- 约定：
--   - 只存 "YYYY-MM-DD" 字符串，比较即字典序比较（避免时区/夏令时把日期抖掉）
--   - 校验走 os.time 回环，非法日期视为普通文本
--   - 完成/归档状态不自动清除 due，视图层自行过滤

local M = {}

local types = require("todo2.store.types")

local DATE_PATTERN = "^%d%d%d%d%-%d%d%-%d%d$"
local DAY = 86400

---------------------------------------------------------------------
-- 基础日期计算
---------------------------------------------------------------------

---今天（本地时区）的 YYYY-MM-DD
---@return string
function M.today()
	return os.date("%Y-%m-%d")
end

---日期字符串 → 当天正午的时间戳（正午可躲开 DST 造成的跨日偏移）
---@param date string YYYY-MM-DD
---@return number|nil
local function timestamp(date)
	local y, m, d = tostring(date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

---日期是否合法（格式 + 真实存在的日历日）
---@param date any
---@return boolean
function M.is_date(date)
	if type(date) ~= "string" or not date:match(DATE_PATTERN) then
		return false
	end
	local ts = timestamp(date)
	return ts ~= nil and os.date("%Y-%m-%d", ts) == date
end

---日期加天数
---@param date string YYYY-MM-DD
---@param n integer 可为负
---@return string|nil
function M.add_days(date, n)
	local ts = timestamp(date)
	if not ts then
		return nil
	end
	return os.date("%Y-%m-%d", ts + (tonumber(n) or 0) * DAY)
end

---某年某月的最后一天
---@param year number
---@param month number
---@return string
local function month_end(year, month)
	local ts = os.time({ year = year, month = month + 1, day = 0, hour = 12 })
	return os.date("%Y-%m-%d", ts)
end

---宽松归一化：YYYY-MM-DD / YYYY/MM/DD / YYYYMMDD / today / tomorrow / yesterday / +Nd / -Nd
---@param value any
---@return string|nil date
---@return string|nil err
function M.normalize(value)
	if type(value) ~= "string" then
		return nil, "due must be a string"
	end
	local v = vim.trim(value):lower():gsub("^@", "")
	if v == "" then
		return nil, "empty due"
	end

	local today = M.today()
	if v == "today" then
		return today
	elseif v == "tomorrow" then
		return M.add_days(today, 1)
	elseif v == "yesterday" then
		return M.add_days(today, -1)
	end

	local rel, sign = v:match("^([%+%-])(%d+)d?$")
	if rel then
		return M.add_days(today, (rel == "-" and -1 or 1) * tonumber(sign))
	end

	local dy, dm, dd = v:match("^(%d%d%d%d)(%d%d)(%d%d)$")
	if dy then
		v = string.format("%s-%s-%s", dy, dm, dd)
	end
	v = v:gsub("/", "-")
	if M.is_date(v) then
		return v
	end
	return nil, "invalid due: " .. tostring(value)
end

---------------------------------------------------------------------
-- 文件行语法：`@YYYY-MM-DD`
---------------------------------------------------------------------

---从文本开头剥离 `@YYYY-MM-DD`，返回到期日与剩余文本。
---@param text string
---@return string|nil due, string rest
function M.extract(text)
	local due, rest = (text or ""):match("^%s*@(%d%d%d%d%-%d%d%-%d%d)(.*)$")
	if due and M.is_date(due) then
		return due, rest
	end
	return nil, text or ""
end

---生成行内片段（带前导空格）；无到期日返回 ""。
---@param due string|nil
---@return string
function M.format(due)
	if not M.is_date(due) then
		return ""
	end
	return " @" .. due
end

---行尾元数据带用的短日期：同年 `MM-DD`，跳年 `YYYY-MM-DD`。
---只影响展示；文件里始终写完整的 `@YYYY-MM-DD`。
---@param due string|nil
---@param today string|nil 参照日（默认今天）
---@return string
function M.format_short(due, today)
	if not M.is_date(due) then
		return ""
	end
	local ref = M.is_date(today) and today or M.today()
	if due:sub(1, 4) == ref:sub(1, 4) then
		return due:sub(6)
	end
	return due
end

---------------------------------------------------------------------
-- 语义判断（渲染 / 排序用）
---------------------------------------------------------------------

---相对今天的紧迫度。
---@param due string|nil
---@param status string|nil 任务状态；终态不产生「过期」语义
---@return "overdue"|"today"|"soon"|"future"|nil
function M.urgency(due, status)
	if not M.is_date(due) then
		return nil
	end
	if status and types.is_completed_status(status) then
		return nil
	end
	local today = M.today()
	if due < today then
		return "overdue"
	elseif due == today then
		return "today"
	elseif due <= M.add_days(today, 3) then
		return "soon"
	end
	return "future"
end

---到期日对应的高亮组。
---@param due string|nil
---@param status string|nil
---@return string|nil
function M.hl(due, status)
	local u = M.urgency(due, status)
	if u == "overdue" then
		return "TodoDueOverdue"
	elseif u == "today" or u == "soon" then
		return "TodoDueSoon"
	elseif u == "future" then
		return "TodoDue"
	end
	return nil
end

---------------------------------------------------------------------
-- 筛选条件（:TodoFilter due:...）
---------------------------------------------------------------------

---解析筛选值：
---   today | tomorrow | week（今天起 7 天）| month（本月）| overdue | none
---   YYYY-MM-DD | YYYY-MM | <DATE | <=DATE | >DATE | >=DATE（DATE 支持相对词）
---@param value string
---@return table|nil spec
---@return string|nil err
function M.parse_spec(value)
	if type(value) ~= "string" or vim.trim(value) == "" then
		return nil, "due: needs a value (today|week|overdue|none|YYYY-MM[-DD])"
	end
	local raw = vim.trim(value)
	local v = raw:lower()
	local today = M.today()

	if v == "overdue" then
		return { kind = "overdue", raw = raw }
	elseif v == "none" then
		return { kind = "none", raw = raw }
	elseif v == "week" then
		return { kind = "range", from = today, to = M.add_days(today, 6), raw = raw }
	elseif v == "month" then
		local y, m = today:match("^(%d%d%d%d)%-(%d%d)")
		return {
			kind = "range",
			from = today:sub(1, 7) .. "-01",
			to = month_end(tonumber(y), tonumber(m)),
			raw = raw,
		}
	end

	local op, rest = v:match("^(<=|>=|<|>)(.+)$")
	if op then
		local date, err = M.normalize(rest)
		if not date then
			return nil, err
		end
		return { kind = "cmp", op = op, date = date, raw = raw }
	end

	if v:match("^%d%d%d%d%-%d%d$") then
		local y, m = v:match("^(%d%d%d%d)%-(%d%d)$")
		local from = v .. "-01"
		local to = month_end(tonumber(y), tonumber(m))
		if not M.is_date(from) then
			return nil, "invalid due: " .. raw
		end
		return { kind = "range", from = from, to = to, raw = raw }
	end

	local date, err = M.normalize(v)
	if not date then
		return nil, err
	end
	return { kind = "day", from = date, to = date, raw = raw }
end

---任务是否命中到期日条件。
---@param due string|nil 任务到期日
---@param spec table|nil M.parse_spec 结果
---@param status string|nil 任务状态（overdue 语义需要）
---@return boolean
function M.hit(due, spec, status)
	if not spec then
		return true
	end
	if spec.kind == "none" then
		return not M.is_date(due)
	end
	if not M.is_date(due) then
		return false
	end
	if spec.kind == "overdue" then
		if status and types.is_completed_status(status) then
			return false
		end
		return due < M.today()
	elseif spec.kind == "day" then
		return due == spec.from
	elseif spec.kind == "range" then
		return due >= spec.from and due <= spec.to
	elseif spec.kind == "cmp" then
		local op = spec.op
		if op == "<" then
			return due < spec.date
		elseif op == "<=" then
			return due <= spec.date
		elseif op == ">" then
			return due > spec.date
		elseif op == ">=" then
			return due >= spec.date
		end
	end
	return false
end

return M
