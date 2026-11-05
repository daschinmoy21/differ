-- The key cheatsheet. Built from the live config so it shows your own bindings.
local M = {}

local api = vim.api
local config = require("differ.config")

--- Join the keys that are set; a key configured to false is left out.
local function keys(...)
  local out = {}
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    if key then
      out[#out + 1] = key
    end
  end
  return table.concat(out, " ")
end

local function sections()
  local k = config.options.keys
  local s, ch, h, cm, c = k.stream, k.changes, k.history, k.commit, k.common
  return {
    { "Everywhere", {
      { keys(c.toggle_tab), "switch between Changes and History" },
      { keys(c.toggle_mode), "unified / side by side" },
      { keys(c.commit), "jump to commit box" },
      { keys(c.refresh), "refresh" },
      { keys(c.help, ch.help), "this help" },
      { keys(c.close), "close" },
      { "<C-hjkl>", "your usual window moves" },
    } },
    { "Diff (main pane)", {
      { keys(s.next_hunk, s.prev_hunk), "next / previous hunk" },
      { keys(s.next_file, s.prev_file, s.next_file_alt, s.prev_file_alt), "next / previous file" },
      { keys(s.stage), "stage or unstage hunk; in visual mode, the selected lines" },
      { keys(s.restore), "restore hunk or selected lines to HEAD" },
      { keys(s.toggle_fold), "collapse or expand file" },
      { keys(s.activate), "open file at this line; on ⋯ reveal hidden lines" },
      { keys(s.stage_all, s.unstage_all), "stage all / unstage all" },
      { keys(s.toggle_wrap), "toggle line wrap" },
      { "i o c d …", "edit added and context lines as usual" },
      { ":w", "write edits back to their files" },
    } },
    { "Changes tab", {
      { keys(ch.activate), "show file; on a section, fold it" },
      { keys(ch.toggle), "toggle stage (works on a visual selection)" },
      { keys(ch.stage, ch.unstage), "stage / unstage" },
      { keys(ch.restore), "discard changes (asks first)" },
      { keys(ch.stage_all, ch.unstage_all), "stage all / unstage all" },
      { keys(ch.toggle_section), "fold section" },
      { keys(ch.commit), "write commit message" },
      { keys(ch.pull, ch.push, ch.fetch), "pull / push / fetch" },
      { keys(ch.prev_tab, ch.next_tab), "History tab" },
    } },
    { "History tab", {
      { keys(h.activate), "show commit" },
      { keys(h.toggle_files), "list the commit's files under it" },
      { keys(h.toggle_all), "current branch / all branches" },
      { keys(h.yank), "yank commit hash" },
      { keys(h.prev_tab, h.next_tab), "Changes tab" },
    } },
    { "Commit box", {
      { keys(cm.submit, cm.submit_alt, ":w"), "commit" },
      { keys(cm.amend), "toggle amend" },
    } },
  }
end

--- Lines of the cheatsheet, and which of them are section titles.
function M.lines()
  local list = sections()
  local width = 0
  for _, section in ipairs(list) do
    for _, row in ipairs(section[2]) do
      width = math.max(width, vim.fn.strdisplaywidth(row[1]))
    end
  end
  local lines, titles = {}, {}
  for i, section in ipairs(list) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = " " .. section[1]
    titles[#titles + 1] = #lines
    for _, row in ipairs(section[2]) do
      if row[1] ~= "" then -- every key in this row was disabled
        local pad = string.rep(" ", width - vim.fn.strdisplaywidth(row[1]))
        lines[#lines + 1] = "  " .. row[1] .. pad .. "  " .. row[2]
      end
    end
  end
  return lines, titles
end

function M.open()
  require("differ.highlight").setup()
  local lines, titles = M.lines()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "differ-help"
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Differ keys ",
    title_pos = "center",
    footer = " q close  ·  :help differ ",
    footer_pos = "center",
  })
  local ns = api.nvim_create_namespace("differ.help")
  for _, line in ipairs(titles) do
    api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { end_col = #lines[line], hl_group = "DifferInfoTitle" })
  end
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?", "g?" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
  return win
end

return M
