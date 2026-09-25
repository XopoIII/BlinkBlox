local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local AUTH_TOKEN
local PATH_TO_TOOLS = "./tools/"
local PATH_TO_PACKAGES = "./packages/"

--> The release asset for the machine this runs on: `macos-aarch64` on an Apple silicon Mac.
local PLATFORM = `{process.os}-{process.arch}`
local EXECUTABLE = if process.os == "windows" then ".exe" else ""

local Tools: { [string]: { Url: string, Binary: string } } = {
	zap = {
		Url = "https://api.github.com/repos/red-blox/zap/releases/latest",
		Binary = "zap",
	},
	blink = {
		Url = "https://api.github.com/repos/XopoIII/BlinkBlox/releases/latest",
		Binary = "blinkblox",
	},
}

local Packages: { [string]: { GitHub: string, Wally: string } } = {
	-- FIXME: Doesn't download correctly
	--[[warp = {
        GitHub = "https://api.github.com/repos/imezx/Warp/releases", 
        Wally = "https://api.wally.run/v1/package-contents/imezx/warp/"
    },]]

	bytenet = {
		GitHub = "https://api.github.com/repos/ffrostflame/ByteNet/releases",
		Wally = "https://api.wally.run/v1/package-contents/ffrostflame/bytenet/",
	},
}

local Versions = {}

if fs.isFile("config.json") then
	local Configuration = serde.decode("json", fs.readFile("config.json"))
	AUTH_TOKEN = Configuration["github-token"]
	print(`Using github token to do API requests!`)
end

local function Curl(URL: string, Output: string, Headers: { string }?): process.ExecResult
	local Arguments = {}

	if AUTH_TOKEN then
		table.insert(Arguments, "--header")
		table.insert(Arguments, `Authorization: Bearer {AUTH_TOKEN}`)
	end

	if Headers then
		for Index, Header in Headers do
			table.insert(Arguments, "--header")
			table.insert(Arguments, Header)
		end
	end

	table.insert(Arguments, "--location")
	table.insert(Arguments, URL)

	table.insert(Arguments, "--output")
	table.insert(Arguments, Output)

	return process.exec("curl", Arguments)
end

--> Unpacks an archive with `tar`, which is bsdtar on macOS and on Windows 10 and later and reads zip
--> as well as tar. GNU tar, on Linux, does not read zip, so there it is `unzip`. This used to be 7-Zip
--> at a fixed Windows path.
local function Extract(Archive: string, Directory: string)
	if not fs.isDir(Directory) then
		fs.writeDir(Directory)
	end

	local IsZip = string.sub(Archive, -4) == ".zip"
	local Result = if IsZip and process.os == "linux"
		then process.exec("unzip", { "-o", "-q", Archive, "-d", Directory })
		else process.exec("tar", { "-xf", Archive, "-C", Directory })

	assert(Result.ok, `Encountered an exception while unpacking {Archive}, {Result.stderr}`)
end

--> The path of the file called `Name` anywhere under `Directory`: an archive may or may not keep its
--> binary in a folder of its own.
local function Find(Directory: string, Name: string): string?
	for _, Entry in fs.readDir(Directory) do
		local Path = `{Directory}/{Entry}`
		if Entry == Name and fs.isFile(Path) then
			return Path
		elseif fs.isDir(Path) then
			local Found = Find(Path, Name)
			if Found then
				return Found
			end
		end
	end

	return nil
end

local function Request(Fetch: net.FetchParams): net.FetchResponse
	if AUTH_TOKEN then
		Fetch.headers = Fetch.headers or {}
		(Fetch.headers :: any).Authorization = `Bearer {AUTH_TOKEN}`
	end

	local Response = net.request(Fetch)
	local Headers = Response.headers :: { [string]: any }
	local Ratelimit = Headers["x-ratelimit-remaining"] :: number

	if tonumber(Ratelimit) == 0 then
		local RetryTimestamp = Headers["x-ratelimit-reset"] :: number
		error(`API rate limit exceeded, retry again in {RetryTimestamp - os.time()} seconds.`)
	end

	assert(Response.ok, Response.statusMessage)
	return Response
end

for Name, Tool in Tools do
	local Response = Request({
		url = Tool.Url,
		method = "GET",
	})

	local Release = serde.decode("json", Response.body)
	local DownloadUrl: string
	local AssetName: string

	for Index, Asset in Release.assets do
		if not string.find(Asset.name, PLATFORM, 1, true) then
			continue
		end

		DownloadUrl = Asset.browser_download_url
		AssetName = Asset.name
	end

	assert(DownloadUrl, `Unable to find a {PLATFORM} download for {Name}`)

	local Archive = `{PATH_TO_TOOLS}{AssetName}`
	local CurlResult = Curl(DownloadUrl, Archive)
	assert(CurlResult.ok, `Encountered an exception while downloading files for {Name}, {CurlResult.code}`)

	local Unpacked = `{PATH_TO_TOOLS}{Name}_unpacked`
	Extract(Archive, Unpacked)

	local Binary = Find(Unpacked, `{Tool.Binary}{EXECUTABLE}`)
	assert(Binary, `The {Name} download holds no {Tool.Binary}{EXECUTABLE}`)
	fs.move(Binary, `{PATH_TO_TOOLS}{Tool.Binary}{EXECUTABLE}`, true)
	fs.removeDir(Unpacked)
	fs.removeFile(Archive)

	if process.os ~= "windows" then
		process.exec("chmod", { "+x", `{PATH_TO_TOOLS}{Tool.Binary}` })
	end

	Versions[Name] = Release.tag_name
	print("Downloaded", Name, Release.tag_name)
end

for Name, Urls in Packages do
	local Response = Request({
		url = Urls.GitHub,
		method = "GET",
	})

	local Releases = serde.decode("json", Response.body)
	table.sort(Releases, function(a, b)
		return a.id > b.id
	end)

	local Release = Releases[1]
	local Version = Release.tag_name
	local PackageVersion = Version

	local ZipPath = `{PATH_TO_PACKAGES}{Name}_ZIP`
	local FinalPath = `{PATH_TO_PACKAGES}{Name}`

	if string.sub(Version, 1, 1) == "v" then
		PackageVersion = string.sub(Version, 2)
	end

	local DownloadUrl = `{Urls.Wally}{PackageVersion}`
	local CurlResult = Curl(DownloadUrl, `{ZipPath}.zip`, { "Wally-Version: 0.3.2" })
	assert(CurlResult.ok, `Encountered an exception while downloading files for {Name}, {CurlResult.stderr}`)

	Extract(`{ZipPath}.zip`, ZipPath)

	fs.move(`{ZipPath}/src`, FinalPath, true)
	fs.removeDir(ZipPath)
	fs.removeFile(`{ZipPath}.zip`)

	Versions[Name] = Version
	print("Downloaded", Name, Version)
end

fs.writeFile("./tools/versions.json", serde.encode("json", Versions))
