-- 到期日三格输入面板的测试
-- 运行：nvim --headless -u NONE -l test/due_panel.lua

local root = vim.fn.getcwd()

local tmp = "/tmp/todo2-due-panel-proj"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")
vim.fn.chdir(tmp)
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.env.XDG_STATE_HOME = tmp .. "/state"
vim.env.XDG_CACHE_HOME = tmp .. "/cache"

local pass, fail = 0, 0
local function check(name, ok, detail)
	if ok then
		pass = pass + 1
		print("PASS " .. name)
	else
		fail = fail + 1
		print("FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
	end
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/../nvim-store3")
vim.cmd("runtime! plugin/todo2.lua")
require("todo2").setup({ todo_files = { pattern = "*.todo.md" } })

local api = vim.api
local due_panel = require("todo2.ui.due_panel")
local due_utils = require("todo2.utils.due")
local config = require("todo2.config")

local notices = {}
vim.notify = function(msg)
	notices[#notices + 1] = tostring(msg)
end

-- 准备一个 TODO 文件并同步
local file = tmp .. "/work.todo.md"
local lines = {
	"# work",
	"",
	"- [ ] todo:panel1 @2026-11-02 task with due",
	"- [ ] todo:panel2 task without due",
}
vim.fn.writefile(lines, file)
vim.cmd("silent! edit! " .. file)
vim.cmd("TodoSync")

local store = require("todo2.store.task.core")

--- 找到三个输入框窗口（按 border title 识别）
local function input_wins()
	local out = {}
	for _, win in ipairs(api.nvim_list_wins()) do
		local cfg = api.nvim_win_get_config(win)
		if cfg.relative ~= "" and cfg.title ~= nil then
			local title = cfg.title
			if type(title) == "table" then
				local acc = {}
				for _, chunk in ipairs(title) do
					acc[#acc + 1] = type(chunk) == "table" and tostring(chunk[1]) or tostring(chunk)
				end
				title = table.concat(acc)
			end
			local name = tostring(title):match("^%s*(.-)%s*$")
			if name == "year" or name == "month" or name == "day" then
				out[name] = { win = win, buf = api.nvim_win_get_buf(win) }
			end
		end
	end
	return out
end

local function parts()
	local wins = input_wins()
	return wins["year"], wins["month"], wins["day"]
end

local function text_of(field)
	if not field then
		return "<missing>"
	end
	return (api.nvim_buf_get_lines(field.buf, 0, -1, false)[1] or "")
end

--- 直接写格子并触发过滤（等价于用户敲字）
local function type_into(field, value)
	api.nvim_buf_set_lines(field.buf, 0, -1, false, { value })
	api.nvim_exec_autocmds("TextChangedI", { buffer = field.buf })
end

--- 父浮窗的预览行（第 3 行）
local function preview_line()
	local wins = input_wins()
	local y = wins["year"]
	if not y then
		return "<no panel>"
	end
	local parent = api.nvim_win_get_config(y.win).win
	local pbuf = api.nvim_win_get_buf(parent)
	return (api.nvim_buf_get_lines(pbuf, 2, 3, false)[1] or "")
end

--- 把焦点放到某格并回车提交
local function submit_from(field)
	api.nvim_set_current_win(field.win)
	vim.cmd("startinsert")
	local cr = api.nvim_replace_termcodes("<CR>", true, false, true)
	api.nvim_feedkeys(cr, "x", false)
end

---------------------------------------------------------------------
-- 1. 打开与预填
---------------------------------------------------------------------
due_panel.open_for("panel1")
check("panel opens", due_panel.is_open())

local y, m, d = parts()
check("three input windows", y ~= nil and m ~= nil and d ~= nil)
check("prefills year", text_of(y) == "2026", text_of(y))
check("prefills month", text_of(m) == "11", text_of(m))
check("prefills day", text_of(d) == "02", text_of(d))
check("preview shows date", preview_line():find("2026%-11%-02") ~= nil, preview_line())

---------------------------------------------------------------------
-- 2. 输入层防呆：非数字被过滤、超长被截断
---------------------------------------------------------------------
type_into(y, "ab20")
check("strips non digits", text_of(y) == "20", text_of(y))

type_into(y, "20261")
check("caps year length", text_of(y) == "2026", text_of(y))

-- 居中只发生在显示层：buffer 里仍是纯数字（否则 sanitize 会振荡）
local function overlay_of(field)
	local ns = api.nvim_get_namespaces()["todo2_due_panel_field_" .. field.buf]
	if not ns then
		return nil
	end
	local marks = api.nvim_buf_get_extmarks(field.buf, ns, 0, -1, { details = true })
	local mark = marks[1]
	return mark and mark[4] and mark[4].virt_text
end

type_into(y, "026")
check("buffer keeps raw digits", text_of(y) == "026", text_of(y))
local ot = overlay_of(y)
check("centering overlay exists", ot ~= nil and ot[1] and ot[1][1] == " 026  ", ot and ot[1] and ot[1][1])
type_into(y, "")
local ot2 = overlay_of(y)
check("empty field pads both sides", ot2 ~= nil and ot2[1][1] == "      ", ot2 and ot2[1] and ot2[1][1])

type_into(d, "3x1")
check("strips non digits in day", text_of(d) == "31", text_of(d))

---------------------------------------------------------------------
-- 3. 语义层防呆：越界归一化 + 预览
---------------------------------------------------------------------
type_into(y, "2026")
type_into(m, "02")
type_into(d, "31")
check("preview clamps 02-31 to 02-28", preview_line():find("2026%-02%-28") ~= nil, preview_line())

type_into(m, "13")
type_into(d, "05")
check("preview clamps month 13 to 12", preview_line():find("2026%-12%-05") ~= nil, preview_line())

type_into(y, "1000")
check("preview clamps year below 1970", preview_line():find("1970%-12%-05") ~= nil, preview_line())

---------------------------------------------------------------------
-- 4. 2 位年份补全
---------------------------------------------------------------------
type_into(y, "27")
check("two digit year becomes 2027", preview_line():find("2027%-12%-05") ~= nil, preview_line())

---------------------------------------------------------------------
-- 5. 填满自动跳格
---------------------------------------------------------------------
local y2, m2, d2 = parts()
api.nvim_set_current_win(y2.win)
vim.cmd("startinsert")
type_into(y2, "2028")
check("auto advances to month", api.nvim_get_current_win() == m2.win, api.nvim_get_current_win())
type_into(m2, "03")
check("auto advances to day", api.nvim_get_current_win() == d2.win, api.nvim_get_current_win())
type_into(d2, "15")
check("stays on last field", api.nvim_get_current_win() == d2.win)

---------------------------------------------------------------------
-- 6. 提交写回 store
---------------------------------------------------------------------
submit_from(parts())
check("panel closed after submit", not due_panel.is_open())
check("store got 2028-03-15", store.get_task("panel1").core.due == "2028-03-15", store.get_task("panel1").core.due)

---------------------------------------------------------------------
-- 7. 快捷值 t（今天）与 x（清除）
---------------------------------------------------------------------
due_panel.open_for("panel1")
vim.api.nvim_set_current_win((parts()).win)
api.nvim_feedkeys("t", "x", false)
local today = due_utils.today()
local fy, fm, fd = parts()
check("shortcut t fills today", text_of(fy) == today:sub(1, 4) and text_of(fm) == today:sub(6, 7), text_of(fy) .. "-" .. text_of(fm))
check("shortcut t fills day", text_of(fd) == today:sub(9, 10), text_of(fd))
submit_from(parts())
check("today written to store", store.get_task("panel1").core.due == today, store.get_task("panel1").core.due)

due_panel.open_for("panel1")
vim.api.nvim_set_current_win((parts()).win)
api.nvim_feedkeys("x", "x", false)
check("shortcut x empties fields", text_of((parts())) == "" and text_of(select(2, parts())) == "")
check("preview shows clear", preview_line():find("clears") ~= nil, preview_line())
submit_from(parts())
check("due cleared in store", store.get_task("panel1").core.due == nil, store.get_task("panel1").core.due)
check("line no longer has @date", not (api.nvim_buf_get_lines(0, 2, 3, false)[1] or ""):find("@20"), api.nvim_buf_get_lines(0, 2, 3, false)[1])

---------------------------------------------------------------------
-- 8. 取消不改动
---------------------------------------------------------------------
due_panel.open_for("panel2")
type_into((parts()), "1999")
vim.api.nvim_set_current_win((parts()).win)
api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
check("panel closed after cancel", not due_panel.is_open())
check("cancel keeps due nil", store.get_task("panel2").core.due == nil, store.get_task("panel2").core.due)

---------------------------------------------------------------------
-- 9. 只输月份日 = 今年
---------------------------------------------------------------------
due_panel.open_for("panel2")
type_into((parts()), "")
type_into(select(2, parts()), "06")
type_into(select(3, parts()), "09")
check("missing year falls back to today's year", preview_line():find(today:sub(1, 4) .. "%-06%-09") ~= nil, preview_line())

---------------------------------------------------------------------
-- 10. 配置关闭时退回表达式输入
---------------------------------------------------------------------
due_panel.close()
config.set("due.panel", false)
local prompt_used = false
vim.ui.input = function()
	prompt_used = true
	return nil
end
require("todo2.handlers.due").due_for_id("panel2")
check("config due.panel = false uses vim.ui.input", prompt_used)

print(("\n%d passed, %d failed"):format(pass, fail))
if fail > 0 then
	vim.cmd("cq")
end
vim.cmd("qa!")
