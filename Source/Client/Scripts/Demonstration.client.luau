--!strict
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Video = require(ReplicatedStorage.Classes.Video)

local Part = workspace:WaitForChild("Demonstration"):WaitForChild("VideoPart")
local VideoGui = Part:FindFirstChild("VideoGui")
local VideoLabel = VideoGui:FindFirstChild("Video")

local EditableImage = AssetService:CreateEditableImage({ Size = Vector2.new(255, 255) })
VideoLabel.ImageContent = Content.fromObject(EditableImage)

local _VideoObject = Video.new("RickRoll", EditableImage, {
	Loop = true,
})
