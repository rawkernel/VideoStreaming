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
	_PackedPalette: { [number]: number },
	_BufferPool: { buffer },
	_BufferPoolIndex: number,

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
	PackedPalette: { [number]: number },
	Width: number,
	Height: number,
	ReuseBuffer: buffer?
): buffer
	local PixelCount: number = Width * Height
	local BufferSize: number = PixelCount * 4

	local Buffer: buffer = if ReuseBuffer and buffer.len(ReuseBuffer) == BufferSize
		then ReuseBuffer
		else buffer.create(BufferSize)

	for i = 0, PixelCount - 1 do
		local RawIndex: number = buffer.readu8(FrameBuffer, i)
		local PaletteIndex: number = RawIndex + 1
		local AlphaValue: number = buffer.readu8(AlphaBuffer, i)
		local PixelOffset: number = i * 4

		local PackedColor: number = PackedPalette[PaletteIndex]
		if PackedColor then
			local PackedPixel: number = bit32.bor(PackedColor, bit32.lshift(AlphaValue, 24))
			buffer.writeu32(Buffer, PixelOffset, PackedPixel)
		else
			local PackedPixel: number = bit32.bor(0x00FFFFFF, bit32.lshift(AlphaValue, 24))
			buffer.writeu32(Buffer, PixelOffset, PackedPixel)
		end
	end

	return Buffer
end

function Methods._BindImageUpdate(self: Schema): RBXScriptConnection
	local Connection: RBXScriptConnection = RunService.Heartbeat:Connect(function(): ()
		if self.State ~= "Playing" then return end
		if not self._EditableImage then return end

		local CurrentTick: number = tick()

		local VideoFrameTime: number = 1 / self.VideoData.FPS
		local TimeSinceLastUpdate: number = CurrentTick - self._LastUpdateTick

		if TimeSinceLastUpdate >= VideoFrameTime then
			local Buffer: buffer = self.VideoData.Frames[self._CurrentFrame]
			local AlphaBuffer: buffer = self.VideoData.Alphas[self._CurrentFrame]

			local poolBuffer: buffer = self._BufferPool[self._BufferPoolIndex]
			local RGBABuffer: buffer = ConvertFrameToRGBA(
				Buffer,
				AlphaBuffer,
				self._PackedPalette,
				self.VideoData.Width,
				self.VideoData.Height,
				poolBuffer
			)

			self._BufferPool[self._BufferPoolIndex] = RGBABuffer
			self._BufferPoolIndex = (self._BufferPoolIndex % 3) + 1

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

	if not VideoData.Palette or #VideoData.Palette == 0 then return nil end
	if not VideoData.Frames or #VideoData.Frames == 0 then return nil end
	if not VideoData.Alphas or #VideoData.Alphas == 0 then return nil end

	local PackedPalette: { [number]: number } = {}
	for Index: never, ColorBuffer: never in VideoData.Palette do
		if ColorBuffer then
			local R: number = buffer.readu8(ColorBuffer, 0)
			local G: number = buffer.readu8(ColorBuffer, 1)
			local B: number = buffer.readu8(ColorBuffer, 2)
			PackedPalette[Index] = bit32.bor(bit32.bor(R, bit32.lshift(G, 8)), bit32.lshift(B, 16))
		end
	end

	local BufferPool: { buffer } = {}
	local BufferSize: never = (VideoData :: FileStreaming.Video).Width * (VideoData :: FileStreaming.Video).Height * 4
	for i = 1, 3 do
		BufferPool[i] = buffer.create(BufferSize)
	end

	local RawSelf: RawSchema = {
		_Connection = nil,
		_EditableImage = EditableImage or nil,
		_Paused = false,
		_CurrentFrame = 1,
		_LastUpdateTick = tick(),
		_Configs = Configs,
		_PackedPalette = PackedPalette,
		_BufferPool = BufferPool,
		_BufferPoolIndex = 1,

		Video = Video,
		State = "Idle",
		VideoData = VideoData :: FileStreaming.Video,
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

	table.clear(self._BufferPool)
end

return Video
