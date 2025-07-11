--!strict
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Reliability = require(ReplicatedFirst.Packages.Reliability)

local FileStreaming = require(ReplicatedStorage.Modules.FileStreaming)

local VideoParser = require(ReplicatedStorage.Modules.VideoParser)

local function ParseVideo(Player: Player, Video: string): FileStreaming.Video?
	local VideoData: FileStreaming.Video? = VideoParser.ParseVideo(Video)
	return VideoData
end

Reliability.getFunction("ClientParseVideo").OnServerInvoke = ParseVideo
