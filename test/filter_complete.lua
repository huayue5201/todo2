-- 过滤表达式补全（回归测试，headless 自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-fc-xdg nvim --headless -u NONE -l test/filter_complete.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-fc-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-fc-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local config = require("todo2.config")
local complete = require("todo2.ui.filter_complete")
local prompt = require("todo2.ui.filter_prompt")

local fails, total = 0, 0
local function check(name, cond, extra)
	total = total + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local function has(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local file = actions.create_todo_file("fc")
actions.create_task({ content = "alpha", path = file.path, tags = { "fix", "frontend" } })
actions.create_task({ content = "beta", path = file.path, tags = { "backend" } })
complete.reset()

---------------------------------------------------------------------
-- 字段名 / 标签值 / 枚举值
---------------------------------------------------------------------
local fields = complete.complete_token("")
check("empty token lists every field", #fields == #complete.FIELDS and has(fields, "tag:"), vim.inspect(fields))
check("fields are the documented seven", #complete.FIELDS == 7, #complete.FIELDS)

local tags = complete.complete_token("tag:")
check("tag values come from project files", has(tags, "tag:fix") and has(tags, "tag:backend"), vim.inspect(tags))
check("tag prefix narrows", vim.deep_equal(complete.complete_token("tag:fr"), { "tag:frontend" }), vim.inspect(complete.complete_token("tag:fr")))

local statuses = complete.complete_token("status:")
check("status values include active", has(statuses, "status:active"), vim.inspect(statuses))
check("status values include the cycle", has(statuses, "status:todo") and has(statuses, "status:doing"), vim.inspect(statuses))

local dues = complete.complete_token("due:")
check("due keywords", has(dues, "due:week") and has(dues, "due:overdue") and has(dues, "due:none"), vim.inspect(dues))
check("start keywords", has(complete.complete_token("start:tom"), "start:tomorrow"))

local axes = complete.complete_token("axis:")
check("axis values", has(axes, "axis:commit") and has(axes, "axis:activity") and has(axes, "axis:all"), vim.inspect(axes))
local scopes = complete.complete_token("scope:t")
check("scope prefix", vim.deep_equal(scopes, { "scope:tree" }), vim.inspect(scopes))
check("unknown field yields nothing", #complete.complete_token("nope:") == 0)

---------------------------------------------------------------------
-- 动作词 / @命名筛选
---------------------------------------------------------------------
config.set("filters", { weekly = { tags = { "fix" } }, mine = { tags = {} } })
local saved = complete.complete_token("@")
check("saved names offered with @", has(saved, "@mine") and has(saved, "@weekly"), vim.inspect(saved))
check("bare name matches too", vim.deep_equal(complete.complete_token("week"), { "weekly" }), vim.inspect(complete.complete_token("week")))
check("action words", has(complete.complete_token("del"), "delete"), vim.inspect(complete.complete_token("del")))
check("bare tag offered as #tag", has(complete.complete_token("#bac"), "#backend"), vim.inspect(complete.complete_token("#bac")))

---------------------------------------------------------------------
-- 整行补全的替换起点
---------------------------------------------------------------------
local items, from = complete.complete("tag:fix sco")
check("line completion uses the last token", vim.deep_equal(items, { "scope:" }), vim.inspect(items))
check(
	"value completion needs the colon",
	vim.deep_equal(complete.complete_token("scope:s"), { "scope:self" }),
	vim.inspect(complete.complete_token("scope:s"))
)
check("from points at the token start", from == 9, from)
local _, from0 = complete.complete("")
check("first token starts at 1", from0 == 1, from0)
check("command-line wrapper delegates", vim.deep_equal(complete.command_line("axis:a"), { "axis:activity", "axis:all" }))

---------------------------------------------------------------------
-- 输入浮窗（打开 / 候选行 / 关闭）
---------------------------------------------------------------------
local submitted, cancelled
prompt.open({
	title = "Filter",
	default = "tag:fix",
	complete = complete.complete,
	on_submit = function(text)
		submitted = text
	end,
	on_cancel = function()
		cancelled = true
	end,
})
check("prompt opens", prompt.is_open())
local pbuf = vim.api.nvim_get_current_buf()
local plines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
check("prompt prefills the default", plines[1] == "tag:fix", plines[1])
check("prompt renders candidates", plines[2] ~= nil and plines[2]:find("tag:fix", 1, true) ~= nil, plines[2])
prompt.close()
check("prompt closes", not prompt.is_open())
check("no submit on close", submitted == nil and cancelled == nil, tostring(submitted))

print(fails == 0 and string.format("ALL PASS (%d checks)", total) or string.format("%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
