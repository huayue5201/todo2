-- scripts/migrate_v2.lua 的端到端测试：dry-run 不改文件、--apply 备份并写回、
-- 迁移结果能被插件解析、重复运行是幂等的。
-- 运行：nvim --headless -u NONE -l test/migrate_v2.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local checks, fails = 0, 0
local function check(name, cond, extra)
	checks = checks + 1
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local base = "/tmp/todo2-migrate-test"
vim.fn.delete(base, "rf")
local vault, store = base .. "/vault", base .. "/store"
vim.fn.mkdir(vault .. "/proj-a", "p")
vim.fn.mkdir(store .. "/proj1", "p")

local path = vault .. "/proj-a/todo.todo.md"
local old = {
	"# Proj A",
	"",
	"## Active",
	"- [ ] todo:ab12cd ~2026-06-20 @2026-07-01 #Fix #backend fix login logic",
	"      需要支持空输入",
	"  - [x] completed:34ef56 handle empty input",
	"- [>] archived:cd34ef old archived task",
	"- [ ] 没有 id 的普通任务",
}
vim.fn.writefile(old, path)
vim.fn.writefile({
	'{"tasks":{'
		.. '"ab12cd":{"timestamps":{"created":1730000000,"updated":1730000100}},'
		.. '"34ef56":{"timestamps":{"created":1730000200,"completed":1730000300}},'
		.. '"cd34ef":{"timestamps":{"created":1730000400,"archived":1730000500}}}}',
}, store .. "/proj1/data.json")

local script = root .. "/scripts/migrate_v2.lua"
local function run(args)
	return vim.fn.system(vim.list_extend({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, args))
end

---------------------------------------------------------------------
-- 1) dry-run 只报告，不动文件
---------------------------------------------------------------------
local out = run({ "--vault=" .. vault, "--store=" .. store })
check("dry-run reports the vault", out:find("DRY%-RUN") ~= nil, out)
check("dry-run does not write", vim.deep_equal(vim.fn.readfile(path), old))
check("dry-run shows a preview", out:find("@id%(ab12cd%)", 1) ~= nil, out)

---------------------------------------------------------------------
-- 2) --apply 写回并备份
---------------------------------------------------------------------
run({ "--vault=" .. vault, "--store=" .. store, "--apply" })
local new = vim.fn.readfile(path)
check("apply rewrites the task lines", not vim.deep_equal(new, old))
check("apply keeps headers and body", new[1] == "# Proj A" and new[5] == "      需要支持空输入", table.concat(new, "\n"))
check(
	"todo line becomes the new grammar",
	new[4] == "- [ ] fix login logic @id(ab12cd) @created(1730000000) @start(2026-06-20) @due(2026-07-01) #backend #fix",
	new[4]
)
check(
	"completed line keeps its checkbox and stamp",
	new[6] == "  - [x] handle empty input @id(34ef56) @created(1730000200) @done(1730000300)",
	new[6]
)
check(
	"archived line keeps `[>]`",
	new[7] == "- [>] old archived task @id(cd34ef) @created(1730000400) @archived(1730000500)",
	new[7]
)
check("task without an id is left alone", new[8] == old[8], new[8])
check("backup of the original is kept", vim.deep_equal(vim.fn.readfile(vault .. "/.migrate-backup/proj-a/todo.todo.md"), old))

---------------------------------------------------------------------
-- 3) 迁移结果能被插件解析，且再跑一次是幂等的
---------------------------------------------------------------------
require("todo2").setup({})
local format = require("todo2.utils.format")
local parsed = format.parse_task_line(new[4])
check("plugin parses the migrated line", parsed and parsed.id == "ab12cd" and parsed.created == 1730000000, vim.inspect(parsed))
check("migrated due/start survive", parsed and parsed.due == "2026-07-01" and parsed.start == "2026-06-20")
check("migrated tags are normalized", parsed and table.concat(parsed.tags, ",") == "backend,fix", parsed and table.concat(parsed.tags, ","))
check("migrated status comes from the checkbox", parsed and parsed.status == "todo", parsed and parsed.status)

local done = format.parse_task_line(new[6])
check("completed status comes from the checkbox", done and done.status == "completed" and done.done == 1730000300, vim.inspect(done))
local archived = format.parse_task_line(new[7])
check("archived status comes from the checkbox", archived and archived.status == "archived", vim.inspect(archived))

local again = run({ "--vault=" .. vault, "--store=" .. store, "--apply" })
check("second run is a no-op", vim.deep_equal(vim.fn.readfile(path), new), again)

---------------------------------------------------------------------
-- 4) 项目目录改名：旧名是项目根的 basename，新名是 <slug>--<hash8>
---------------------------------------------------------------------
local repo = base .. "/repo"
vim.fn.mkdir(repo, "p")
vim.fn.system({ "git", "-C", repo, "init", "-q" })
vim.fn.mkdir(vault .. "/repo", "p")
vim.fn.writefile({ "- [ ] todo:aa11bb old name dir task" }, vault .. "/repo/todo.todo.md")
vim.fn.mkdir(store .. "/proj2", "p")
vim.fn.writefile({ vim.json.encode({ root = vim.fn.resolve(repo), accessed_at = os.time() }) }, store .. "/proj2/meta.json")

local project = require("todo2.utils.project")
local expected = project.get_project_name(repo)
local out4 = run({ "--vault=" .. vault, "--store=" .. store, "--apply" })
check("dir: renamed to the identity name", vim.fn.isdirectory(vault .. "/" .. expected) == 1, out4)
check("dir: old name is gone", vim.fn.isdirectory(vault .. "/repo") == 0, out4)
check("dir: skipped legacy dirs are reported", out4:find("unknown") ~= nil, out4)
local manifest_path = vault .. "/" .. expected .. "/.project.json"
check("dir: manifest written", vim.fn.filereadable(manifest_path) == 1, manifest_path)
local manifest = vim.json.decode(table.concat(vim.fn.readfile(manifest_path), "\n"))
check("dir: manifest records the root", manifest.root == vim.fn.resolve(repo), vim.inspect(manifest))
local moved = vim.fn.readfile(vault .. "/" .. expected .. "/todo.todo.md")
check(
	"dir: file inside was migrated too",
	moved[1] == "- [ ] old name dir task @id(aa11bb)",
	moved[1]
)

vim.fn.delete(base, "rf")
print("")
if fails == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(fails .. " FAILED of " .. checks)
	os.exit(1)
end
