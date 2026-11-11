std = "lua54"
max_line_length = false
codes = true
-- Faithful ports of Go code keep upstream names and structure, so some
-- warnings that are noisy for mechanical translations are relaxed.
ignore = {
  "212", -- unused argument (Go interface methods keep their signatures)
  "213", -- unused loop variable
  "311", -- value assigned to a local is overwritten before use (Go zero values)
  "542", -- empty if branch (ported switch/case fallthrough shapes)
}
exclude_files = { "vendor/", "lua_modules/", ".luarocks/" }
files["spec/"] = { std = "+busted" }
