local Process = require("@lune/process")
local Task = require("@lune/task")

Task.spawn(function(): ()
    Process.exec("rojo", {
        "sourcemap",
        "--output",
        "sourcemap.json",
        "--watch",
        "--include-non-scripts",
    }, {
        stdio = "forward",
    })
end)

Task.spawn(function(): ()
    Process.exec("rojo", {
        "serve",
    }, {
        stdio = "forward",
    })
end)
