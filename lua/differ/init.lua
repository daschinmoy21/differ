local M = {}

--- Configure Differ. Optional: everything works with the defaults.
function M.setup(opts)
  require("differ.config").setup(opts)
end

--- Open (or focus) the view.
function M.open(opts)
  return require("differ.app").open(opts)
end

--- Open the view, or close it if you're already in it.
function M.toggle()
  return require("differ.app").toggle()
end

function M.close()
  local app = require("differ.app").current
  if app then
    app:close()
  end
end

--- Open the commit graph, optionally limited to one file.
function M.history(path)
  return require("differ.app").history(path)
end

--- Show the key cheatsheet. Works without an open view.
function M.help()
  return require("differ.help").open()
end

function M.refresh()
  local app = require("differ.app").current
  if app then
    app:refresh(true)
  end
end

return M
