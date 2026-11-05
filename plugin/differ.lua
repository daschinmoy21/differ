if vim.g.loaded_differ then
  return
end
vim.g.loaded_differ = true

local subcommands = {
  open = function() require("differ").open() end,
  toggle = function() require("differ").toggle() end,
  close = function() require("differ").close() end,
  refresh = function() require("differ").refresh() end,
  help = function() require("differ").help() end,
  history = function(arg)
    local path = arg ~= "" and vim.fn.fnamemodify(vim.fn.expand(arg), ":p") or nil
    require("differ").history(path)
  end,
}

vim.api.nvim_create_user_command("Differ", function(cmd)
  local name, rest = (cmd.args or ""):match("^(%S*)%s*(.*)$")
  name = name == "" and "toggle" or name
  local fn = subcommands[name]
  if not fn then
    vim.notify("Differ: unknown subcommand " .. name, vim.log.levels.ERROR)
    return
  end
  fn(rest)
end, {
  nargs = "*",
  complete = function(lead, line)
    if line:match("^%S+%s+history%s") then
      return vim.fn.getcompletion(lead, "file")
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
  end,
  desc = "Git changes, history and diffs",
})
