std = "lua51"
read_globals = { "import", "_PLUGIN", "LOC", "WIN_ENV", "MAC_ENV" }
-- Lightroom's Lua sandbox strips these; use LrFileUtils / LrTasks instead.
not_globals = { "os.rename", "os.remove", "os.execute", "os.exit", "os.tmpname", "os.setlocale" }
