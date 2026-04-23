-- temper_platform.lua — Cross-platform shell helpers
local M = {}

local _is_windows = (jit and jit.os == "Windows")

--- Reveal a file or folder in the OS file manager (highlights the file).
--- @param path string  File or folder path (forward slashes OK)
function M.reveal_in_explorer(path)
  if _is_windows then
    path = path:gsub("/", "\\")
  end
  if reaper.CF_LocateInExplorer then
    reaper.CF_LocateInExplorer(path)
  elseif reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(path)
  end
end

--- Open a folder in the OS file manager (shows folder contents, no file highlight).
--- @param folder string  Folder path
function M.open_folder(folder)
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(folder)
  elseif _is_windows then
    os.execute('start "" "' .. folder:gsub("/", "\\") .. '"')
  else
    os.execute('open "' .. folder .. '"')
  end
end

return M
