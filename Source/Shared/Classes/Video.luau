--!strict
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Reliability = require(ReplicatedFirst.Packages.Reliability)

local FileStreaming = require(ReplicatedStorage.Modules.FileStreaming)

local Video = {}
local Methods = {}

type State = "Idle" | "Playing" | "Paused" | "Stopped"

type RawSchema = {
	_Connection: RBXScriptConnection?,
	_EditableImage: EditableImage?,
	_CurrentFrame: number,
	_LastUpdateTick: number,
	_Paused: boolean,
	_Configs: Configs,

	Video: string,
	State: State,
	VideoData: FileStreaming.Video,
}
type MethodsSchema = {
	_BindImageUpdate: (self: Schema) -> (),
	SetEditableImage: (self: Schema, EditableImage: EditableImage) -> (),
	Pause: (self: Schema) -> (),
	Resume: (self: Schema) -> (),
	Destroy: (self: Schema) -> (),
}
export type Schema = typeof(setmetatable({} :: RawSchema, { __index = {} :: MethodsSchema }))

export type Configs = {
	Loop: boolean?,
}

local function ConvertFrameToRGBA(
	FrameBuffer: buffer,
	AlphaBuffer: buffer,
	Palette: { [number]: buffer },
	Width: number,
	Height: number
): buffer
	local PixelCount: number = Width * Height
	local Buffer = buffer.create(PixelCount * 4)

	for i = 0, PixelCount - 1 do
		local RawIndex: number = buffer.readu8(FrameBuffer, i)
		local PaletteIndex: number = RawIndex + 1
		local AlphaValue: number = buffer.readu8(AlphaBuffer, i)

		local PaletteColorBuffer: buffer = Palette[PaletteIndex]
		if not PaletteColorBuffer then
			buffer.writeu8(Buffer, i * 4, 255) -- R
			buffer.writeu8(Buffer, i * 4 + 1, 255) -- G
			buffer.writeu8(Buffer, i * 4 + 2, 255) -- B
			buffer.writeu8(Buffer, i * 4 + 3, AlphaValue) -- A
			continue
		end

		local R: number = buffer.readu8(PaletteColorBuffer, 0)
		local G: number = buffer.readu8(PaletteColorBuffer, 1)
		local B: number = buffer.readu8(PaletteColorBuffer, 2)

		buffer.writeu8(Buffer, i * 4, R)
		buffer.writeu8(Buffer, i * 4 + 1, G)
		buffer.writeu8(Buffer, i * 4 + 2, B)
		buffer.writeu8(Buffer, i * 4 + 3, AlphaValue)
	end

	return Buffer
end

function Methods._BindImageUpdate(self: Schema): RBXScriptConnection
	local Connection: RBXScriptConnection = RunService.Heartbeat:Connect(function(): ()
		if self.State ~= "Playing" then return end
		if not self._EditableImage then return end

		local CurrentTick: number = tick()

		-- Calculate proper frame timing based on video FPS
		local VideoFrameTime: number = 1 / self.VideoData.FPS -- Time each video frame should be displayed
		local TimeSinceLastUpdate: number = CurrentTick - self._LastUpdateTick

		-- Only update when enough time has passed for the next video frame
		if TimeSinceLastUpdate >= VideoFrameTime then
			local Buffer: buffer = self.VideoData.Frames[self._CurrentFrame]
			local AlphaBuffer: buffer = self.VideoData.Alphas[self._CurrentFrame]

			local RGBABuffer: buffer = ConvertFrameToRGBA(
				Buffer,
				AlphaBuffer,
				self.VideoData.Palette,
				self.VideoData.Width,
				self.VideoData.Height
			)

			if self._EditableImage then
				self._EditableImage:WritePixelsBuffer(
					Vector2.new(0, 0),
					Vector2.new(self.VideoData.Width, self.VideoData.Height),
					RGBABuffer
				)
			end

			self._CurrentFrame += 1

			if self._CurrentFrame > #self.VideoData.Frames then
				if self._Configs.Loop then
					self._CurrentFrame = 1
				else
					self.State = "Stopped"
					if self._Connection then self._Connection:Disconnect() end
				end
			end

			-- Simple timing update - just set to current time
			-- This ensures consistent frame rate without drift accumulation
			self._LastUpdateTick = CurrentTick
		end
	end)

	self._Connection = Connection
	return Connection
end

function Methods.SetEditableImage(self: Schema, EditableImage: EditableImage): ()
	if not EditableImage then
		warn("EditableImage cannot be nil.")
		return
	end

	self._EditableImage = EditableImage
end

function Methods.Pause(self: Schema): ()
	if self.State == "Stopped" then
		warn("Cannot pause a stopped video.")
		return
	end

	self.State = "Paused"
end

function Methods.Resume(self: Schema): ()
	if self.State == "Stopped" then
		warn("Cannot resume a stopped video.")
		return
	end

	self.State = "Playing"
	-- Reset timing to prevent immediate frame advancement
	self._LastUpdateTick = tick()
end

function Video.new(Video: string, EditableImage: EditableImage, Configs: Configs): Schema?
	Configs = Configs or ({
		Loop = false,
	} :: Configs)

	local VideoData: FileStreaming.Video? = nil
	if RunService:IsClient() then
		VideoData = Reliability.getFunction("ClientParseVideo"):InvokeServer(Video) :: FileStreaming.Video?
	else
		local VideoParser = require(ReplicatedStorage.Modules.VideoParser)
		VideoData = VideoParser.ParseVideo(Video)
	end
	if not VideoData then
		warn(string.format("Failed to parse video data for '%s'", Video))
		return nil
	end

	-- Validate video data integrity
	if not VideoData.Palette or #VideoData.Palette == 0 then return nil end

	if not VideoData.Frames or #VideoData.Frames == 0 then return nil end

	if not VideoData.Alphas or #VideoData.Alphas == 0 then return nil end

	local RawSelf: RawSchema = {
		_Connection = nil,
		_EditableImage = EditableImage or nil,
		_Paused = false,
		_CurrentFrame = 1,
		_LastUpdateTick = tick(), -- Initialize with current time for proper timing
		_Configs = Configs,

		Video = Video,
		State = "Idle",
		VideoData = VideoData,
	}
	local self: Schema = setmetatable(RawSelf, { __index = Methods :: MethodsSchema })

	self.State = "Playing"
	self:_BindImageUpdate()

	return self :: Schema
end

function Methods.Destroy(self: Schema): ()
	if self._EditableImage then self._EditableImage:Destroy() end

	self._EditableImage = nil
	self.State = "Stopped"
	if self._Connection then self._Connection:Disconnect() end
end

return Video
