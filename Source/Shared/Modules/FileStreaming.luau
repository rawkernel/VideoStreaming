--!strict
local HttpService = game:GetService("HttpService")

export type Video = {
	Width: number,
	Height: number,
	Palette: { [number]: buffer },
	Frames: { [number]: buffer },
	Alphas: { [number]: buffer },
	FrameCount: number,
	FPS: number,
}

local function StringToBuffer(String: string): buffer
	local Buffer = buffer.create(string.len(String))
	for i = 1, string.len(String) do
		buffer.writeu8(Buffer, i - 1, string.byte(String, i) :: number)
	end
	return Buffer
end

local FileStreaming = {}

function FileStreaming.ParseBuffer(Buffer: buffer): Video
	local Width: number = buffer.readu16(Buffer, 0)
	local Height: number = buffer.readu16(Buffer, 2)
	local PaletteSize: number = buffer.readu8(Buffer, 4)
	local FrameCount: number = buffer.readu8(Buffer, 5)

	local FrameSize: number = Width * Height
	local PaletteByteSize: number = PaletteSize * 3
	local FramesByteSize: number = FrameCount * FrameSize

	local PaletteOffset: number = 6
	local Palette: { [number]: buffer } = {}
	for i = 1, PaletteSize do
		local PaletteBuffer: buffer = buffer.create(3)
		local Offset: number = PaletteOffset + (i - 1) * 3

		local R: number = buffer.readu8(Buffer, Offset)
		local G: number = buffer.readu8(Buffer, Offset + 1)
		local B: number = buffer.readu8(Buffer, Offset + 2)

		buffer.writeu8(PaletteBuffer, 0, R)
		buffer.writeu8(PaletteBuffer, 1, G)
		buffer.writeu8(PaletteBuffer, 2, B)

		Palette[i] = PaletteBuffer
	end

	local FramesOffset: number = PaletteOffset + PaletteByteSize
	local Frames: { [number]: buffer } = {}
	for i = 1, FrameCount do
		local FrameBuffer: buffer = buffer.create(FrameSize)
		local Offset: number = FramesOffset + (i - 1) * FrameSize
		for j = 0, FrameSize - 1 do
			local PixelIndex: number = buffer.readu8(Buffer, Offset + j)
			buffer.writeu8(FrameBuffer, j, PixelIndex)
		end
		Frames[i] = FrameBuffer
	end

	local AlphaOffset: number = FramesOffset + FramesByteSize
	local Alphas: { [number]: buffer } = {}
	for i = 1, FrameCount do
		local AlphaBuffer: buffer = buffer.create(FrameSize)
		local Offset: number = AlphaOffset + (i - 1) * FrameSize
		for j = 0, FrameSize - 1 do
			local AlphaValue: number = buffer.readu8(Buffer, Offset + j)
			buffer.writeu8(AlphaBuffer, j, AlphaValue)
		end
		Alphas[i] = AlphaBuffer
	end

	local EstimatedFPS: number = 24

	if FrameCount <= 20 then
		EstimatedFPS = 30
	elseif FrameCount >= 100 then
		EstimatedFPS = 18
	end

	return {
		Width = Width,
		Height = Height,
		Palette = Palette,
		Frames = Frames,
		Alphas = Alphas,
		FrameCount = FrameCount,
		FPS = EstimatedFPS,
	}
end

function FileStreaming.GetVideoDataAsync(Video: string): Video?
	local URL: string = string.format("http://localhost:8080/video?file=%s.gif", Video)
	local Success: boolean, RawResponse: string = pcall(function(): string
		return HttpService:GetAsync(URL)
	end)
	if not Success then
		warn(string.format("Failed to fetch video data from URL: %s. %s", URL, RawResponse))
		return nil
	end

	local ResponseBuffer: buffer = StringToBuffer(RawResponse)
	return FileStreaming.ParseBuffer(ResponseBuffer)
end

return FileStreaming
