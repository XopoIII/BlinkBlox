--!strict
--- Bundle the actual committed generator output into the single script OCALE accepts. Keeping this
--- generated file out of git avoids a second golden copy; CI rebuilds it before every local/cloud run.
local fs = require("@lune/fs")

local templatePath = "scripts/ocale/conformance.luau"
local codecPath = "test/Golden/Datatypes/DatatypesServer.luau"
local outputDirectory = "build/ocale"
local outputPath = `{outputDirectory}/conformance.luau`
local marker = "%-%- @GENERATED_DATATYPES_SERVER@"

local template = fs.readFile(templatePath)
local codec = fs.readFile(codecPath)
local first, last = template:find(marker)
assert(first and last and not template:find(marker, last + 1), "Expected one generated-codec marker")

local bundle = template:sub(1, first - 1) .. codec .. template:sub(last + 1)
if not fs.isDir(outputDirectory) then
	fs.writeDir(outputDirectory)
end
fs.writeFile(outputPath, bundle)
print(`Built {outputPath} from {codecPath}`)
