local path = require "nvim-lsp-installer.path"
local fs = require "nvim-lsp-installer.fs"
local installers = require "nvim-lsp-installer.installers"
local std = require "nvim-lsp-installer.installers.std"
local platform = require "nvim-lsp-installer.platform"
local process = require "nvim-lsp-installer.process"

local M = {}

local yarn = platform.is_win and "yarn.cmd" or "yarn"

local function ensure_yarn(installer)
    return installers.pipe {
        std.ensure_executables {
            { "node", "node was not found in path. Refer to https://nodejs.org/en/." },
            {
                "yarn",
                "yarn was not found in path.",
            },
        },
        installer,
    }
end

function M.packages(packages)
    return ensure_yarn(function(server, callback, context)
        local c = process.chain {
            cwd = server.root_dir,
            stdio_sink = context.stdio_sink,
        }
        -- force it to keep the node_modules in the same folder
        c.run(yarn, vim.list_extend({ "add", "--non-interactive", "--modules-folder", "./node_modules" }, packages))
        c.spawn(callback)
    end)
end

-- @alias for packages
M.install = M.packages

function M.exec(executable, args)
    return function(server, callback, context)
        process.spawn(M.executable(server.root_dir, executable), {
            args = args,
            cwd = server.root_dir,
            stdio_sink = context.stdio_sink,
        }, callback)
    end
end

function M.run(script)
    return ensure_yarn(function(server, callback, context)
        process.spawn(yarn, {
            args = { "run", script },
            cwd = server.root_dir,
            stdio_sink = context.stdio_sink,
        }, callback)
    end)
end

function M.executable(root_dir, executable)
    return path.concat {
        root_dir,
        "node_modules",
        ".bin",
        platform.is_win and ("%s.cmd"):format(executable) or executable,
    }
end

return M
