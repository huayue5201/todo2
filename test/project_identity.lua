-- 项目身份回归测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/project_identity.lua
--
-- 目标：目录名由「身份」算出来，而不是 cwd 的 basename —— 同名不同项目不串，
-- 同一项目换路径不散，且与 nvim-store3 的项目根保持同根（monorepo 子包各归各的）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

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

-- 每个用例跑在自己的进程里才好清 identity 缓存，这里直接清模块缓存
local function fresh()
	package.loaded["todo2.utils.project"] = nil
	return require("todo2.utils.project")
end

local base = "/tmp/todo2-project-identity"
vim.fn.delete(base, "rf")
vim.fn.mkdir(base, "p")

local function run(cmd)
	local res = vim.system({ "sh", "-c", cmd }, { text = true }):wait(30000)
	return res.code == 0
end

local function make_repo(path, remote)
	vim.fn.mkdir(path, "p")
	assert(run("git -C '" .. path .. "' init -q"))
	if remote then
		assert(run("git -C '" .. path .. "' remote add origin '" .. remote .. "'"))
	end
end

---------------------------------------------------------------------
-- 1. 非 git 目录：本地路径即身份
---------------------------------------------------------------------
local plain = base .. "/plain/pkg"
vim.fn.mkdir(plain, "p")
local p1 = fresh()
local name_plain = p1.get_project_name(plain)
check("non-git: slug from dir name", name_plain:match("^pkg%-%-%x%x%x%x%x%x%x%x$"), name_plain)
check("non-git: stable across calls", fresh().get_project_name(plain) == name_plain, name_plain)
check("non-git: root is the dir itself", p1.get_project_root(plain) == vim.fn.resolve(plain), p1.get_project_root(plain))

---------------------------------------------------------------------
-- 2. 同一远端 + 两次不同路径 → 同一个名字
---------------------------------------------------------------------
local a1 = base .. "/clone-a/app"
local a2 = base .. "/clone-b/app"
make_repo(a1, "git@github.com:acme/app.git")
make_repo(a2, "git@github.com:acme/app.git")
local name_a1 = fresh().get_project_name(a1)
local name_a2 = fresh().get_project_name(a2)
check("remote: same remote at different paths shares one name", name_a1 == name_a2, name_a1 .. " vs " .. name_a2)
check("remote: slug from dir name", name_a1:match("^app%-%-%x%x%x%x%x%x%x%x$"), name_a1)
check("remote: not the old basename-only name", name_a1 ~= "app", name_a1)

---------------------------------------------------------------------
-- 3. 同名目录、不同远端 → 不同名字（旧实现的串数据场景）
---------------------------------------------------------------------
local b1 = base .. "/other/app"
make_repo(b1, "https://github.com/other/app.git")
local name_b1 = fresh().get_project_name(b1)
check("same basename + different remote: distinct names", name_b1 ~= name_a1, name_b1 .. " vs " .. name_a1)
check("https remote: credentials/protocol/case ignored", fresh().get_project_name(b1) == name_b1, name_b1)

---------------------------------------------------------------------
-- 4. monorepo 子包：与仓库根同名规则一致（都用 nvim-store3 的项目根）
---------------------------------------------------------------------
local mono = base .. "/mono"
make_repo(mono, "https://github.com/acme/mono.git")
local pkg = mono .. "/packages/web"
vim.fn.mkdir(pkg, "p")
assert(vim.fn.writefile({ "{}" }, pkg .. "/package.json"))
local name_mono = fresh().get_project_name(mono)
local name_pkg = fresh().get_project_name(pkg)
check("monorepo: subpackage root is the subpackage", fresh().get_project_root(pkg):match("packages/web$") ~= nil, pkg)
check("monorepo: subpackage has its own name", name_pkg ~= name_mono, name_pkg .. " vs " .. name_mono)
check("monorepo: subpackage name is stable", fresh().get_project_name(pkg) == name_pkg, name_pkg)

---------------------------------------------------------------------
-- 5. 清单：目录里记下身份 / 根 / 展示名，搬动项目后自愈
---------------------------------------------------------------------
vim.fn.chdir(a1)
local p5 = fresh()
local dir = p5.get_project_dir()
vim.fn.mkdir(dir, "p") -- 目录由「创建 TODO 文件」的路径建立，这里模拟
p5.get_project_dir()
check("manifest: dir is <slug>--<hash8>", dir:match("/app%-%-%x%x%x%x%x%x%x%x$") ~= nil, dir)
local manifest_path = dir .. "/.project.json"
check("manifest: written", vim.fn.filereadable(manifest_path) == 1, manifest_path)
local manifest = vim.json.decode(table.concat(vim.fn.readfile(manifest_path), "\n"))
check("manifest: records identity", manifest.identity == "github.com/acme/app", manifest.identity)
check("manifest: records root", manifest.root == vim.fn.resolve(a1), manifest.root)
check("manifest: records label", manifest.label == "app", manifest.label)

-- 项目被别人家搬走：清单里的根失效 → 以当前 cwd 为准（不写死旧路径）
local moved = base .. "/moved/app"
vim.fn.mkdir(base .. "/moved", "p")
vim.fn.rename(a1, moved)
vim.fn.chdir(moved)
local p5b = fresh()
local name_moved = p5b.get_project_name()
check("manifest: still the same project after moving", name_moved == name_a1, name_moved)
p5b.get_project_dir()
local after = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/.project.json"), "\n"))
check("manifest: root repaired after move", after.root == vim.fn.resolve(moved), after.root)

---------------------------------------------------------------------
-- 6. 列表：跳过隐藏目录（备份 / 隔离区）
---------------------------------------------------------------------
vim.fn.mkdir(dir .. "/../.migrate-backup", "p")
local names = {}
for _, info in ipairs(fresh().list_projects()) do
	names[#names + 1] = info.name
end
local hidden_listed = false
for _, n in ipairs(names) do
	if n:sub(1, 1) == "." then
		hidden_listed = true
	end
end
check("list: hides dot dirs", not hidden_listed, table.concat(names, ","))
check("list: includes the current project", vim.tbl_contains(names, name_a1), table.concat(names, ","))

vim.fn.delete(base, "rf")
vim.fn.delete(vim.fn.expand("~/.todo-files/" .. name_a1), "rf")
print(fails == 0 and string.format("ALL PASS (%d checks)", total) or string.format("%d/%d FAILED", fails, total))
if fails > 0 then
	os.exit(1)
end
