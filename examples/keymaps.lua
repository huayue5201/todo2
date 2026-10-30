-- examples/keymaps.lua
--
-- 推荐键位（复制进你的配置，或直接 require）。
-- todo2 只注册 `:Todo` 系列命令和极少数「智能回退」键，不占用 <leader> 前缀；
-- 下面这套是作者自己用的，可按需删改。
--
-- 统一入口是 `:Todo <sub>`（等价于 `:Todo<Sub>`），所以记不住命令时先按 <leader>md 看抽屉。

local map = function(lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { desc = "todo2: " .. desc })
end

-- 入口 / 总览
map("<leader>md", "<cmd>Todo<cr>", "task drawer (project tree)")
map("<leader>mh", "<cmd>Todo help<cr>", "help")
map("<leader>mg", "<cmd>TodoCalendar<cr>", "calendar")
map("<leader>mq", "<cmd>TodoFloat<cr>", "task view in a floating window")

-- 单条任务
map("<leader>mt", "<cmd>TodoToggle<cr>", "toggle the task under the cursor")
map("<leader>mT", "<cmd>TodoToggleSel<cr>", "toggle selection (visual: :'<,'>TodoToggleSel)")
map("<leader>ms", "<cmd>TodoStatus<cr>", "set the status")
map("<leader>mv", "<cmd>TodoDue<cr>", "set the due date")
map("<leader>m#", "<cmd>TodoTag<cr>", "set tags")
map("<leader>mr", "<cmd>TodoRename<cr>", "rename")
map("<leader>mx", "<cmd>TodoDel<cr>", "delete (has children? use :TodoDel! or :TodoPromote)")
map("<leader>mP", "<cmd>TodoPromote<cr>", "delete only this task, keep children")

-- 新建
map("<leader>mn", "<cmd>TodoNew<cr>", "new task in the TODO file")
map("<leader>me", "<cmd>TodoInsert<cr>", "new task anchored to this code line")
map("<leader>mE", "<cmd>TodoInsertSub<cr>", "new subtask anchored to this code line")

-- 代码 ↔ 任务
map("<leader>mj", "<cmd>TodoJump<cr>", "jump task → code / code → tasks")
map("<leader>mc", "<cmd>TodoContext<cr>", "show the linked code block")
map("<leader>mC", "<cmd>TodoLink<cr>", "link this code line to a task")

-- 浏览 / 过滤
map("<leader>m/", "<cmd>TodoFilter<cr>", "filter (same syntax as :TodoFilter)")
map("<leader>m?", "<cmd>TodoFilter!<cr>", "clear the filter (`:TodoFilter!`)")
map("<leader>mo", "<cmd>TodoSort<cr>", "sort")
map("<leader>ma", "<cmd>TodoArchive<cr>", "archive completed tasks")
map("<leader>mA", "<cmd>TodoArchiveView<cr>", "browse the archive")
map("<leader>mQ", "<cmd>TodoArchiveQF<cr>", "archive → quickfix")

-- 维护
map("<leader>mS", "<cmd>TodoSync<cr>", "rescan TODO files into the store")
map("<leader>mR", "<cmd>TodoReconcile<cr>", "reconcile store vs files")
map("<leader>mD", "<cmd>TodoDoctor<cr>", "self-check")
map("<leader>mH", "<cmd>checkhealth todo2<cr>", "health check")

-- 插件自带、无需重复映射：
--   * 可视模式 `<BS>` —— 删除选中的多个任务（含子树）
--   * 普通模式 `<BS>` —— 光标在任务行上时删除该任务，否则回退原生退格
--   * 抽屉里 `C` —— 在任务到期日那天打开日历
