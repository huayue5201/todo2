-- 任务筛选（标签 / 状态 / 路径 + 命名筛选 + 抽屉排序）回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-filter-xdg nvim --headless -u NONE -l test/filter.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local sibling_store = vim.fn.fnamemodify(root, ":h") .. "/nvim-store3"
vim.opt.runtimepath:prepend(sibling_store)
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-filter-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-filter-proj"), "rf")

require("todo2").setup({})

local f = require("todo2.render.filter")
local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")
local filter_cmd = require("todo2.handlers.filter").filter_cmd
local config = require("todo2.config")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

---------------------------------------------------------------------
-- 词法 / 规格
---------------------------------------------------------------------
local spec, err = f.parse({ "fix", "status:Todo", "status:active", "path:src\\", "#git:dirty" })
check("parse ok", spec ~= nil, err)
check(
	"tags normalized",
	#spec.tags == 2 and spec.tags[1] == "fix" and spec.tags[2] == "git:dirty",
	vim.inspect(spec.tags)
)
check("status resolved + deduped", #spec.status == 2 and spec.status[1] == "todo", vim.inspect(spec.status))
check("path slashes normalized", spec.path == "src/")
check("describe", f.describe(spec) == "#fix #git:dirty status:todo status:active path:src/", f.describe(spec))
check("round-trip", vim.deep_equal(spec, f.from_table(f.to_table(spec))))
check("empty", f.is_empty(f.parse({})))
local bad, berr = f.parse({ "status:nope" })
check("unknown status rejected", bad == nil and berr ~= nil)

local task = {
	core = { tags = { "fix", "backend" }, status = "doing" },
	locations = { todo = { path = "/p/a.todo.md" }, code = { path = "/p/src/x.lua" } },
}
check("tag+status+path match", f.task_matches(task, f.parse({ "fix", "status:active", "path:src/" })))
check("status exact", f.task_matches(task, f.parse({ "status:doing" })))
check("status mismatch", not f.task_matches(task, f.parse({ "status:todo" })))
check("path glob", f.task_matches(task, f.parse({ "path:*.lua" })))
check("path miss", not f.task_matches(task, f.parse({ "path:nope" })))
task.core.status = "completed"
check("active excludes terminal", not f.task_matches(task, f.parse({ "status:active" })))

---------------------------------------------------------------------
-- TODO 文件：隐藏不匹配行
---------------------------------------------------------------------
local file = actions.create_todo_file("filter")
actions.create_task({ content = "alpha task", path = file.path, tags = { "fix" } })
local beta = actions.create_task({ content = "beta task", path = file.path, tags = { "backend" } })
actions.create_task({ content = "gamma task", path = file.path })
actions.set_status(beta.id, "doing")
vim.cmd.edit(vim.fn.fnameescape(file.path))

local function rows_by_text()
	local rows = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
		rows[m[2] + 1] = true
	end
	return rows
end

local function line_of(needle)
	for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if l:find(needle, 1, true) then
			return i
		end
	end
end

filter_cmd({ fargs = { "fix" } })
local rows = rows_by_text()
local alpha_row, beta_row = line_of("alpha task"), line_of("beta task")
check("buffer filter: hit stays", alpha_row and not rows[alpha_row], alpha_row)
check("buffer filter: miss hidden", beta_row and rows[beta_row] == true, beta_row)

filter_cmd({ fargs = { "status:doing" } })
rows = rows_by_text()
check("status filter: doing stays", not rows[beta_row], beta_row)
check("status filter: todo hidden", rows[alpha_row] == true, alpha_row)

filter_cmd({ fargs = {}, bang = true })
check(
	"cleared",
	f.active(vim.api.nvim_get_current_buf()) == nil
		and #vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}) == 0
)

---------------------------------------------------------------------
-- 命名筛选
---------------------------------------------------------------------
filter_cmd({ fargs = { "save", "work", "fix", "status:active" } })
check("saved to config", type(config.get("filters").work) == "table", vim.inspect(config.get("filters")))
check("saved table shape", config.get("filters").work.tags[1] == "fix")
filter_cmd({ fargs = { "@work" } })
check("named filter applied", f.describe(f.active(vim.api.nvim_get_current_buf())) == "#fix status:active")
check("persisted to .todo2/config.json", config._load_config().filters.work.tags[1] == "fix")
config.current = vim.deepcopy(config.defaults)
config.setup({})
check("saved filters survive setup", config.get("filters").work ~= nil)
filter_cmd({ fargs = { "delete", "work" } })
check("deleted", config.get("filters").work == nil)
filter_cmd({ fargs = { "@work" } }) -- 不存在：只告警，不应抛错

---------------------------------------------------------------------
-- 抽屉：筛选 + 排序
---------------------------------------------------------------------
drawer.toggle()
vim.wait(300, function()
	return false
end)
local dbuf = vim.api.nvim_get_current_buf()
check("drawer open", drawer.is_drawer(dbuf))
drawer.set_filter(f.parse({ "fix" }))
local dlines = table.concat(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "\n")
check("drawer filter keeps hit", dlines:find("alpha task", 1, true) ~= nil)
check("drawer filter hides miss", dlines:find("beta task", 1, true) == nil)
check("drawer file count", dlines:find("matched", 1, true) ~= nil)

drawer.clear_filter()
drawer.sort_cmd({ fargs = { "status" } })
dlines = vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
local function idx(needle)
	for i, l in ipairs(dlines) do
		if l:find(needle, 1, true) then
			return i
		end
	end
end
check(
	"sort: todo siblings together, doing after",
	idx("alpha task") < idx("gamma task") and idx("gamma task") < idx("beta task")
)
drawer.sort_cmd({ fargs = { "default" } })

---------------------------------------------------------------------
-- scope: 默认只显示命中项；scope:tree 连带子树
---------------------------------------------------------------------
local sync = require("todo2.core.sync")
vim.cmd.edit(vim.fn.fnameescape(file.path))
local flocked = vim.api.nvim_buf_get_lines(0, 0, -1, false)
flocked[#flocked + 1] = "- [ ] todo:sct001 #fix parent matched"
flocked[#flocked + 1] = "  - [ ] todo:sct002 child one"
flocked[#flocked + 1] = "  - [ ] todo:sct003 child two"
vim.api.nvim_buf_set_lines(0, 0, -1, false, flocked)
sync.sync_todo_file(file.path)

local spec_self = f.parse({ "#fix" })
local spec_tree = f.parse({ "#fix", "scope:tree" })
check("scope: default is unset", spec_self.scope == nil, tostring(spec_self.scope))
check("scope:tree parsed", spec_tree.scope == "tree", tostring(spec_tree.scope))
check("scope: describe", f.describe(spec_tree):find("scope:tree", 1, true) ~= nil, f.describe(spec_tree))
check("scope: roundtrip", f.from_table(f.to_table(spec_tree)).scope == "tree")
local bad_scope, bad_scope_err = f.parse({ "scope:kid" })
check("scope: unknown value rejected", bad_scope == nil and bad_scope_err ~= nil, bad_scope_err)
check("scope: self accepted as explicit default", f.parse({ "scope:self" }).scope == nil)

filter_cmd({ fargs = { "#fix" } })
rows = rows_by_text()
check("scope:self hides descendants", rows[line_of("child one")] == true, line_of("child one"))
check("scope:self keeps the parent", not rows[line_of("parent matched")])

filter_cmd({ fargs = { "#fix", "scope:tree" } })
rows = rows_by_text()
check("scope:tree keeps descendants", not rows[line_of("child one")])
check("scope:tree keeps the parent", not rows[line_of("parent matched")])
filter_cmd({ fargs = {}, bang = true })

-- 抽屉可能还开着（上一节没关）：找现有的抽屉 buffer，没有才 toggle 开一个
local function find_drawer()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if drawer.is_drawer(b) then
			return b, w
		end
	end
end
local dbuf2, dwin2 = find_drawer()
-- 抽屉可能处于"内部认为开着、窗口已没"的状态，toggle 最两次
for _ = 1, 2 do
	if dbuf2 then
		break
	end
	drawer.toggle()
	vim.wait(400, function()
		dbuf2, dwin2 = find_drawer()
		return dbuf2 ~= nil
	end, 20)
	dbuf2, dwin2 = find_drawer()
end
check("drawer available for scope assertions", dbuf2 ~= nil)
vim.api.nvim_set_current_win(dwin2)
drawer.set_filter(spec_self)
dlines = table.concat(vim.api.nvim_buf_get_lines(dbuf2, 0, -1, false), "\n")
check("drawer scope:self hides children", dlines:find("child one", 1, true) == nil)
check("drawer shows the hidden count", dlines:find("+2", 1, true) ~= nil, dlines)
drawer.set_filter(spec_tree)
dlines = table.concat(vim.api.nvim_buf_get_lines(dbuf2, 0, -1, false), "\n")
check("drawer scope:tree shows children", dlines:find("child one", 1, true) ~= nil)
drawer.clear_filter()
print(fails == 0 and "ALL OK" or ("FAILURES: " .. fails))
vim.cmd(fails == 0 and "qall!" or "cquit")
