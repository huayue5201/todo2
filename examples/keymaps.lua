-- examples/keymaps.lua
--
-- 推荐键位（复制进你的配置，或直接 require）。
-- todo2 只注册 `:Todo` 系列命令和极少数「智能回退」键，不占用 <leader> 前缀。
--
-- 键位约定（一套可以推导出来的规则，不是零散记忆）：
--   全局 = <leader>m<组><动作>；抽屉里的单键 == 那个动作字母（大小写一致）。
--   组字母 = 语义域：t 任务 / f 文件 / v 视图 / a 归档 / l 链接 / g git。
--   例：抽屉 D 设到期日 ↔ <leader>mtD；抽屉 o 预览 ↔ <leader>mvo。
--   抽屉里少数动作没有对应全局键（<CR> 切状态、<BS> 删任务、y/d/p 剪切粘贴、
--   C 月历点选、R 刷新、折叠键 zi/zo/zc/zR/zM），它们只在一个地方有意义。

local map = function(lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { desc = "todo2: " .. desc })
end

-- 入口
map("<leader>md", "<cmd>Todo<cr>", "task drawer (project tree)")
map("<leader>mh", "<cmd>Todo help<cr>", "help (`:h todo2`)")
map("<leader>mc", "<cmd>TodoAdd<cr>", "new task from this code line (`:TodoInsert` = plain task)")

-- 任务组（末位 == 抽屉键）
map("<leader>mts", "<cmd>TodoStatus<cr>", "pick a status          (drawer s)")
map("<leader>mtt", "<cmd>TodoTag<cr>", "edit tags             (drawer t)")
map("<leader>mtD", "<cmd>TodoDue<cr>", "set/clear the due date (drawer D)")
map("<leader>mtS", "<cmd>TodoStart<cr>", "set/clear the start date (drawer S)")
map("<leader>mtC", "<cmd>TodoCalendar<cr>", "open the calendar (drawer C: pick a date there)")
map("<leader>mti", "<cmd>TodoSet<cr>", "status/tags/start/due in one panel (drawer i)")
map("<leader>mte", "<cmd>TodoTask rename<cr>", "edit the task title    (drawer e)")
map("<leader>mtE", "<cmd>TodoTask desc<cr>", "edit the task body     (drawer E)")
map("<leader>mtc", "<cmd>TodoContext<cr>", "copy task context as Markdown (drawer c)")
map("<leader>mtl", "<cmd>TodoLink<cr>", "link this code line to a task")
map("<leader>mtf", "<cmd>TodoFilter<cr>", "filter (drawer f)")
map("<leader>mtF", "<cmd>TodoFilter!<cr>", "clear the filter (drawer F)")
map("<leader>mtO", "<cmd>TodoSort<cr>", "sort siblings by status (drawer O)")

-- 视图组（末位 == 抽屉键）
map("<leader>mvo", "<cmd>TodoView float<cr>", "preview in a floating window (drawer o)")
map("<leader>mvP", "<cmd>TodoView preview<cr>", "smart preview TODO/code (drawer P: code only)")
map("<leader>mvs", "<cmd>TodoView split<cr>", "open in a horizontal split")
map("<leader>mvv", "<cmd>TodoView vsplit<cr>", "open in a vertical split")
map("<leader>mve", "<cmd>TodoView edit<cr>", "open for editing")
map("<leader>mvc", "<cmd>TodoCalendar<cr>", "project calendar (time dimension)")

-- 文件组（末位 == 抽屉键；抽屉里在文件头按 a/r/d）
map("<leader>mfa", "<cmd>TodoFile new<cr>", "new TODO file (drawer a)")
map("<leader>mfr", "<cmd>TodoFile rename<cr>", "rename file (drawer r)")
map("<leader>mfd", "<cmd>TodoFile delete<cr>", "delete file (drawer d on a file header)")

-- 归档组
map("<leader>max", "<cmd>TodoArchive<cr>", "archive the task group (drawer x)")
map("<leader>mau", "<cmd>TodoUnarchive<cr>", "restore archived tasks")
map("<leader>mav", "<cmd>TodoArchiveView<cr>", "browse the archive (tree)")
map("<leader>maq", "<cmd>TodoArchiveView!<cr>", "browse the archive (quickfix list)")

-- 链接组
map("<leader>mla", "<cmd>TodoLinks<cr>", "all code links (quickfix)")
map("<leader>mlb", "<cmd>TodoLinks!<cr>", "links in this buffer (loclist)")

-- git 组（抽屉内 gs/gr/gb 同字母）
map("<leader>mgs", "<cmd>TodoGit sync<cr>", "apply commit-message references (drawer gs)")
map("<leader>mgr", "<cmd>TodoGit review<cr>", "check dirty files for task anchors (drawer gr)")
map("<leader>mgb", "<cmd>TodoGit blame<cr>", "history of this task's code (drawer gb)")

-- 维护（没有抽屉对应动作）
map("<leader>mS", "<cmd>TodoSync<cr>", "rescan TODO files into the store")
map("<leader>mR", "<cmd>TodoSync!<cr>", "reconcile store vs files")
map("<leader>mD", "<cmd>TodoDoctor<cr>", "self-check")
map("<leader>mH", "<cmd>checkhealth todo2<cr>", "health check")
