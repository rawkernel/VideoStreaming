**CONSTANTS** always **SCREAMING_SNAKE_CASE**
**FUNCTIONS** always **PascalCase**
**VARIABLES** always **PascalCase**
**FILE NAMES** always **PascalCase**
**CLASS CONSTRUCTORS** always **camelCase**
**CLASS METHODS** always **PascalCase**
**METHODS** always **PascalCase**
**CLASS NAMES** always **PascalCase**
**ENUMS** always **PascalCase**
**DO NOT** use **ipairs** or **pairs**, use **generic iteration** instead
**--!strict** flag at the top of every file that does not use Vide library
**ALWAYS** strictly type your variables, parameters, return values and function signatures
**ALWAYS** use **type annotations** for all variables, parameters, return values and function signatures
**Guard clauses** over **nesting** ifs
**init.luau** files means the ancestor folder is a module, the init.luau file represents the module itself, the full name of the file is init.luau
When creating a new module with **init.luau**, make sure to create a new folder for it with the name of the system you are creating
**Client** **scripts** are **.client.luau** files, if you wish to make a Folder be a Client script, use **init.client.luau** as the name of the script
**Server** **scripts** are **.server.luau** files, if you wish to make a Folder be a Server script, use **init.server.luau** as the name of the script
Folders can not contain multiple **.init.luau** files
**ALWAYS** generate API documentation inside the Documentation folder
When using **guard clauses**, never use error()
**SetPrimaryPartCFrame** is old, use **PivotTo** for both Model and BasePart
**DO NOT** use game.Workspace or game:GetService("Workspace"), use only **workspace** keyword instead
When using **pcall**, try not to create a function to return another function´s call, just call it directly, example: local Success = pcall(InserService.LoadAsset, InsertService, AssetId)
**NEVER HARDCODE** numbers, use constants instead

## GENERIC iteration
```luau
local MyTable = {
    ["Item1"] = 100,
    ["Item2"] = 200,
    ["Item3"] = 300,
}
for Name, Price in MyTable do 

end
```