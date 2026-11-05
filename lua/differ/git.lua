-- Thin wrapper around the git CLI. Everything that returns data parses the
-- machine-readable, NUL-delimited forms so odd filenames are safe.
local M = {}

local ENV = {
  GIT_TERMINAL_PROMPT = "0",
  GIT_OPTIONAL_LOCKS = "0", -- our polling must never rewrite the index
  GIT_EDITOR = "true",
  GIT_PAGER = "cat",
  LC_ALL = "C",
}

local function argv(args)
  local cmd = { "git", "-c", "core.quotepath=off", "-c", "color.ui=false", "-c", "log.showSignature=false" }
  return vim.list_extend(cmd, args)
end

local function sys_opts(root, opts)
  opts = opts or {}
  return { cwd = root, env = ENV, text = false, stdin = opts.stdin }
end

--- Run git asynchronously. `cb(ok, stdout, stderr)` runs on the main loop.
function M.run(root, args, opts, cb)
  if type(opts) == "function" then
    cb, opts = opts, nil
  end
  local ok, err = pcall(vim.system, argv(args), sys_opts(root, opts), function(res)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "", res.stderr or "")
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "", tostring(err))
    end)
  end
end

--- Run git and wait. Returns ok, stdout, stderr.
function M.sync(root, args, opts)
  local res = vim.system(argv(args), sys_opts(root, opts)):wait()
  return res.code == 0, res.stdout or "", res.stderr or ""
end

--- Locate the repository containing `path`. Returns root, gitdir or nil.
function M.find_root(path)
  local dir = path
  local stat = dir and vim.uv.fs_stat(dir)
  if not stat then
    dir = vim.uv.cwd()
  elseif stat.type ~= "directory" then
    dir = vim.fs.dirname(dir)
  end
  local ok, out = M.sync(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
  if not ok then
    return nil
  end
  local parts = vim.split(vim.trim(out), "\n", { plain = true })
  return parts[1], parts[2]
end

function M.empty_tree(root)
  local ok, out = M.sync(root, { "hash-object", "-t", "tree", "/dev/null" })
  return ok and vim.trim(out) or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
end

local function split_nul(s)
  local out, pos = {}, 1
  while pos <= #s do
    local e = s:find("\0", pos, true)
    if not e then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, e - 1)
    pos = e + 1
  end
  return out
end

--- Parse `git diff --numstat -z` into { [path] = { adds, dels, binary } }.
function M.parse_numstat(out)
  local stats, parts, i = {}, split_nul(out), 1
  while i <= #parts do
    local a, d, path = parts[i]:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
    i = i + 1
    if a then
      if path == "" then -- rename: old and new follow as separate fields
        path = parts[i + 1]
        i = i + 2
      end
      if path then
        stats[path] = { adds = tonumber(a) or 0, dels = tonumber(d) or 0, binary = a == "-" }
      end
    end
  end
  return stats
end

local function fields_then_path(entry, count)
  -- Splits off `count` space-separated fields; the rest is the path verbatim.
  local fields, pos = {}, 1
  for _ = 1, count do
    local e = entry:find(" ", pos, true)
    if not e then
      return nil
    end
    fields[#fields + 1] = entry:sub(pos, e - 1)
    pos = e + 1
  end
  return fields, entry:sub(pos)
end

--- Parse `git status --porcelain=v2 --branch -z`.
function M.parse_status(out)
  local status = { branch = "HEAD", ahead = 0, behind = 0, files = {} }
  local parts, i = split_nul(out), 1
  while i <= #parts do
    local entry = parts[i]
    i = i + 1
    local t = entry:sub(1, 1)
    if t == "#" then
      local key, value = entry:match("^# (%S+) (.*)$")
      if key == "branch.head" then
        status.branch = value == "(detached)" and "detached" or value
      elseif key == "branch.oid" then
        status.oid = value
        status.unborn = value == "(initial)"
      elseif key == "branch.upstream" then
        status.upstream = value
      elseif key == "branch.ab" then
        local a, b = value:match("%+(%d+) %-(%d+)")
        status.ahead, status.behind = tonumber(a) or 0, tonumber(b) or 0
      end
    elseif t == "1" then
      local f, path = fields_then_path(entry, 8)
      if f then
        status.files[#status.files + 1] = {
          kind = "tracked", path = path, x = f[2]:sub(1, 1), y = f[2]:sub(2, 2),
          mode_index = f[5], mode_work = f[6], head_oid = f[7], index_oid = f[8],
        }
      end
    elseif t == "2" then
      local f, path = fields_then_path(entry, 9)
      local orig = parts[i]
      i = i + 1
      if f then
        status.files[#status.files + 1] = {
          kind = "tracked", path = path, old_path = orig, x = f[2]:sub(1, 1), y = f[2]:sub(2, 2),
          mode_index = f[5], mode_work = f[6], head_oid = f[7], index_oid = f[8],
        }
      end
    elseif t == "u" then
      local f, path = fields_then_path(entry, 10)
      if f then
        status.files[#status.files + 1] = {
          kind = "conflict", path = path, x = f[2]:sub(1, 1), y = f[2]:sub(2, 2),
          mode_index = f[4], mode_work = f[7], head_oid = f[8], index_oid = f[9],
        }
      end
    elseif t == "?" then
      status.files[#status.files + 1] = { kind = "untracked", path = entry:sub(3), x = "?", y = "?" }
    end
  end
  return status
end

--- Status plus per-file line counts. `cb(status|nil, err)`.
function M.status(root, cb)
  M.run(root, { "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all" }, function(ok, out, err)
    if not ok then
      return cb(nil, err)
    end
    local status = M.parse_status(out)
    local base = status.unborn and M.empty_tree(root) or "HEAD"
    M.run(root, { "diff", "--no-ext-diff", "--numstat", "-z", "-M", base }, function(ok2, out2)
      local stats = ok2 and M.parse_numstat(out2) or {}
      for _, file in ipairs(status.files) do
        local s = stats[file.path]
        if s then
          file.adds, file.dels, file.binary = s.adds, s.dels, s.binary
        end
      end
      cb(status)
    end)
  end)
end

local function parse_batch(out, count)
  local results, pos = {}, 1
  for i = 1, count do
    local nl = out:find("\n", pos, true)
    if not nl then
      break
    end
    local header = out:sub(pos, nl - 1)
    local size = header:match("^%x+ %a+ (%d+)$")
    if size then
      size = tonumber(size)
      results[i] = out:sub(nl + 1, nl + size)
      pos = nl + size + 2
    else
      pos = nl + 1 -- "<name> missing"
    end
  end
  return results
end

--- Read many objects with one process. `cb(results)`; missing specs are nil.
function M.cat_file(root, specs, cb)
  if #specs == 0 then
    return cb({})
  end
  M.run(root, { "cat-file", "--batch", "-z" }, { stdin = table.concat(specs, "\0") .. "\0" }, function(ok, out)
    cb(ok and parse_batch(out, #specs) or {})
  end)
end

function M.cat_file_sync(root, specs)
  local ok, out = M.sync(root, { "cat-file", "--batch", "-z" }, { stdin = table.concat(specs, "\0") .. "\0" })
  return ok and parse_batch(out, #specs) or {}
end

--- Read a worktree file. Returns text, or nil when absent or not a regular file.
function M.read_work(root, path)
  local full = root .. "/" .. path
  local stat = vim.uv.fs_stat(full)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local fd = io.open(full, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

local SEP, REC = "\0", "\30"

--- One page of history. `cb(commits|nil, err)`.
function M.log(root, opts, cb)
  local fmt = table.concat({ "%H", "%h", "%P", "%an", "%ct", "%D", "%s" }, "%x00") .. "%x1e"
  local args = { "log", "--topo-order", "--decorate=short", "--format=" .. fmt, "-n", tostring(opts.count), "--skip=" .. (opts.skip or 0) }
  if opts.all then
    args[#args + 1] = "--all"
  end
  if opts.path then
    -- --parents rewrites %P to the simplified history so the graph still connects.
    vim.list_extend(args, { "--parents", "--", opts.path })
  end
  M.run(root, args, function(ok, out, err)
    if not ok then
      return cb(nil, err)
    end
    local commits = {}
    for record in out:gmatch("([^" .. REC .. "]+)" .. REC) do
      local f = vim.split(record:gsub("^\n", ""), SEP, { plain = true })
      if f[1] and f[1] ~= "" then
        commits[#commits + 1] = {
          hash = f[1], short = f[2],
          parents = f[3] ~= "" and vim.split(f[3], " ", { plain = true }) or {},
          author = f[4], time = tonumber(f[5]) or 0, refs = f[6] or "", subject = f[7] or "",
        }
      end
    end
    cb(commits)
  end)
end

--- Files changed between two revisions. `cb(files)` in the status file shape.
function M.diff_files(root, base, rev, cb)
  M.run(root, { "diff", "--no-ext-diff", "--name-status", "-z", "-M", base, rev }, function(ok, out)
    if not ok then
      return cb({})
    end
    local files, parts, i = {}, split_nul(out), 1
    while i <= #parts do
      local code = parts[i]
      local letter = code:sub(1, 1)
      if letter == "R" or letter == "C" then
        files[#files + 1] = { kind = "commit", old_path = parts[i + 1], path = parts[i + 2], x = letter, y = "." }
        i = i + 3
      else
        files[#files + 1] = { kind = "commit", path = parts[i + 1], x = letter, y = "." }
        i = i + 2
      end
    end
    M.run(root, { "diff", "--no-ext-diff", "--numstat", "-z", "-M", base, rev }, function(ok2, out2)
      local stats = ok2 and M.parse_numstat(out2) or {}
      for _, file in ipairs(files) do
        local s = stats[file.path]
        if s then
          file.adds, file.dels, file.binary = s.adds, s.dels, s.binary
        end
      end
      cb(files)
    end)
  end)
end

--- Full message and metadata of a commit. `cb(info|nil)`.
function M.commit_info(root, rev, cb)
  M.run(root, { "show", "-s", "--format=%H%x00%an <%ae>%x00%ct%x00%D%x00%P%x00%B", rev }, function(ok, out)
    if not ok then
      return cb(nil)
    end
    local f = vim.split(out, SEP, { plain = true })
    cb({
      hash = f[1], author = f[2], time = tonumber(f[3]) or 0, refs = f[4] or "",
      parents = (f[5] or "") ~= "" and vim.split(f[5], " ", { plain = true }) or {},
      body = vim.trim(f[6] or ""),
    })
  end)
end

--- Git's own short-form age, e.g. "4 weeks ago".
function M.relative_time(ts, now)
  local d = (now or os.time()) - ts
  local function unit(n, name)
    n = math.floor(n)
    return n .. " " .. name .. (n == 1 and "" or "s") .. " ago"
  end
  if d < 60 then return "just now" end
  if d < 3600 then return unit(d / 60, "minute") end
  if d < 86400 then return unit(d / 3600, "hour") end
  if d < 86400 * 7 then return unit(d / 86400, "day") end
  if d < 86400 * 30 then return unit(d / (86400 * 7), "week") end
  if d < 86400 * 365 then return unit(d / (86400 * 30), "month") end
  return unit(d / (86400 * 365), "year")
end

return M
