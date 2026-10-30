std = "lua51"
globals = { "vim" }
max_line_length = false
unused_args = false
ignore = {
	"631", -- line is too long (我 们 不 限 制 行 宽)
	"212", -- unused argument (回调签名需要)
}
