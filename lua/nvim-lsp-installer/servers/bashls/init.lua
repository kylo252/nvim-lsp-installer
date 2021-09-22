local server = require "nvim-lsp-installer.server"
local npm = require "nvim-lsp-installer.installers.npm"
local yarn = require "nvim-lsp-installer.installers.yarn"

return function(name, root_dir)
    return server.Server:new {
        name = name,
        root_dir = root_dir,
        installer = yarn.packages { "bash-language-server@latest" },
        default_options = {
            cmd = { yarn.executable(root_dir, "bash-language-server"), "start" },
        },
    }
end
