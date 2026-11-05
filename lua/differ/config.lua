local M = {}

M.defaults = {
  sidebar = { position = "right", width = 46 },
  commit_height = 5,
  context = 3, -- unchanged lines around each hunk
  expand_step = 20, -- lines revealed per <CR> on a "hidden lines" row
  mode = "unified", -- "unified" (all files, one buffer) or "split" (side by side, one file)

  -- Big repos: only this many changed lines load up front; the rest load as you
  -- scroll to them. A single file over max_file_lines needs an explicit <CR>.
  load_budget = 8000,
  max_file_lines = 6000,
  max_syntax_bytes = 512 * 1024,

  follow = true, -- moving through the sidebar previews in the main pane
  poll_ms = 3000, -- re-check git status while the view is focused; 0 disables
  confirm_restore = true, -- ask before discarding work

  history = { page = 200, all = false, max_lanes = 8 },

  icons = {
    unchecked = "☐",
    checked = "☑",
    partial = "▣",
    expanded = "▾",
    collapsed = "▸",
    branch = "\u{e0a0}", -- Powerline branch glyph; needs a Nerd Font
    bar = "▌",
    bar_staged = "┃",
    bar_partial = "┇",
    bar_edit = "▎",
  },

  -- Set any key to false to leave that key alone. <C-hjkl>, leader maps and the
  -- like are never touched; all of this is buffer-local to Differ's own windows.
  keys = {
    common = {
      close = "q",
      help = "g?",
      refresh = "R",
      toggle_mode = "gS",
      toggle_tab = "gh",
      commit = "gC",
    },
    stream = {
      stage = "-",
      restore = "X",
      next_hunk = "]c",
      prev_hunk = "[c",
      next_file = "]f",
      prev_file = "[f",
      next_file_alt = "L",
      prev_file_alt = "H",
      toggle_fold = "<Tab>",
      activate = "<CR>",
      stage_all = "gA",
      unstage_all = "gR",
      toggle_wrap = "gW",
    },
    changes = {
      activate = "<CR>",
      stage = "s",
      unstage = "u",
      toggle = "-",
      restore = "X",
      stage_all = "a",
      unstage_all = "A",
      toggle_section = "<Tab>",
      commit = "c",
      help = "?",
      push = "P",
      pull = "p",
      fetch = "f",
      next_tab = "L",
      prev_tab = "H",
    },
    history = {
      activate = "<CR>",
      toggle_files = "<Tab>",
      yank = "y",
      toggle_all = "a",
      help = "?",
      next_tab = "L",
      prev_tab = "H",
    },
    commit = {
      submit = "<C-s>",
      submit_alt = "<C-CR>",
      amend = "<M-a>",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
