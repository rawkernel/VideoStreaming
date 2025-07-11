--!strict
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if RunService:IsClient() then error("VideoParser must be used on the server") end

local FileStreaming = require(ReplicatedStorage.Modules.FileStreaming)

local DataStore = DataStoreService:GetDataStore("VIDEO_STREAMING")
local CHUNK_SIZE: number = 3 * 1024 * 1024
local MAX_RLE_COUNT: number = 255

local VideoParser = {}
local VideoCache: { [string]: FileStreaming.Video } = {}

local BASE64_CHARS: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_DECODE_TABLE: { [number]: number } = {}

do
	for i = 1, 64 do
		BASE64_DECODE_TABLE[string.byte(BASE64_CHARS, i)] = i - 1
	end
end

local function EncodeBufferToBase64(Data: buffer): string
	local DataLength: number = buffer.len(Data)
	if DataLength == 0 then return "" end

	local PadCount: number = (3 - (DataLength % 3)) % 3
	local EncodedLength: number = math.ceil(DataLength / 3) * 4
	local Result: { string } = {}
	local ResultIndex: number = 1

	for ByteIndex = 0, DataLength - 1, 3 do
		local B1: number = buffer.readu8(Data, ByteIndex)
		local B2: number = if ByteIndex + 1 < DataLength then buffer.readu8(Data, ByteIndex + 1) else 0
		local B3: number = if ByteIndex + 2 < DataLength then buffer.readu8(Data, ByteIndex + 2) else 0

		local Combined: number = bit32.bor(bit32.lshift(B1, 16), bit32.lshift(B2, 8), B3)

		-- Extract 6-bit chunks efficiently
		local C1: number = bit32.rshift(Combined, 18) + 1
		local C2: number = bit32.band(bit32.rshift(Combined, 12), 0x3F) + 1
		local C3: number = bit32.band(bit32.rshift(Combined, 6), 0x3F) + 1
		local C4: number = bit32.band(Combined, 0x3F) + 1

		Result[ResultIndex] = string.sub(BASE64_CHARS, C1, C1)
		Result[ResultIndex + 1] = string.sub(BASE64_CHARS, C2, C2)
		Result[ResultIndex + 2] = string.sub(BASE64_CHARS, C3, C3)
		Result[ResultIndex + 3] = string.sub(BASE64_CHARS, C4, C4)
		ResultIndex += 4
	end

	if PadCount > 0 then
		for i = 1, PadCount do
			Result[EncodedLength - i + 1] = "="
		end
	end

	return table.concat(Result)
end

local function DecodeBase64ToBuffer(Data: string): buffer
	if string.len(Data) == 0 then return buffer.create(0) end

	local CleanData: string = string.gsub(Data, "=", "")
	local CleanLength: number = string.len(CleanData)
	local OutputLength: number = math.floor(CleanLength * 3 / 4)

	if OutputLength <= 0 then return buffer.create(0) end

	local Result: buffer = buffer.create(OutputLength)
	local ResultIndex: number = 0
	local DataBytes: buffer = buffer.fromstring(CleanData)

	local ChunkEnd: number = CleanLength - (CleanLength % 4)
	for ByteIndex = 0, ChunkEnd - 4, 4 do
		local C1: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ByteIndex)] or 0
		local C2: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ByteIndex + 1)] or 0
		local C3: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ByteIndex + 2)] or 0
		local C4: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ByteIndex + 3)] or 0

		local Combined: number = bit32.bor(bit32.lshift(C1, 18), bit32.lshift(C2, 12), bit32.lshift(C3, 6), C4)

		buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 16), 0xFF))
		buffer.writeu8(Result, ResultIndex + 1, bit32.band(bit32.rshift(Combined, 8), 0xFF))
		buffer.writeu8(Result, ResultIndex + 2, bit32.band(Combined, 0xFF))
		ResultIndex += 3
	end

	local Remainder: number = CleanLength % 4
	if Remainder >= 2 and ResultIndex < OutputLength then
		local C1: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ChunkEnd)] or 0
		local C2: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ChunkEnd + 1)] or 0
		local Combined: number = bit32.bor(bit32.lshift(C1, 18), bit32.lshift(C2, 12))

		buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 16), 0xFF))
		ResultIndex += 1

		if Remainder == 3 and ResultIndex < OutputLength then
			local C3: number = BASE64_DECODE_TABLE[buffer.readu8(DataBytes, ChunkEnd + 2)] or 0
			Combined = bit32.bor(Combined, bit32.lshift(C3, 6))
			buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 8), 0xFF))
		end
	end

	return Result
end

local function CompressBufferRLE(InputBuffer: buffer, ExpectedSize: number): buffer
	local InputSize: number = math.min(buffer.len(InputBuffer), ExpectedSize)
	if InputSize == 0 then
		local Result: buffer = buffer.create(1)
		buffer.writeu8(Result, 0, 0)
		return Result
	end

	local TempBuffer: buffer = buffer.create(InputSize * 2)
	local WriteIndex: number = 0

	local ReadIndex: number = 0
	while ReadIndex < InputSize do
		local CurrentValue: number = buffer.readu8(InputBuffer, ReadIndex)
		local RunLength: number = 1

		while ReadIndex + RunLength < InputSize and RunLength < MAX_RLE_COUNT do
			if buffer.readu8(InputBuffer, ReadIndex + RunLength) == CurrentValue then
				RunLength += 1
			else
				break
			end
		end

		if RunLength >= 3 then
			buffer.writeu8(TempBuffer, WriteIndex, bit32.bor(0x80, RunLength - 3))
			buffer.writeu8(TempBuffer, WriteIndex + 1, CurrentValue)
			WriteIndex += 2
		else
			for i = 0, RunLength - 1 do
				buffer.writeu8(TempBuffer, WriteIndex, CurrentValue)
				WriteIndex += 1
			end
		end

		ReadIndex += RunLength
	end

	local Result: buffer = buffer.create(WriteIndex)
	buffer.copy(Result, 0, TempBuffer, 0, WriteIndex)
	return Result
end

local function DecompressBufferRLE(CompressedBuffer: buffer, ExpectedSize: number, DefaultValue: number): buffer
	local Result: buffer = buffer.create(ExpectedSize)
	local CompressedSize: number = buffer.len(CompressedBuffer)
	local WriteIndex: number = 0
	local ReadIndex: number = 0

	if DefaultValue ~= 0 then
		for i = 0, ExpectedSize - 1 do
			buffer.writeu8(Result, i, DefaultValue)
		end
	end

	while WriteIndex < ExpectedSize and ReadIndex < CompressedSize do
		local ControlByte: number = buffer.readu8(CompressedBuffer, ReadIndex)
		ReadIndex += 1

		if bit32.band(ControlByte, 0x80) ~= 0 then
			local RunLength: number = bit32.band(ControlByte, 0x7F) + 3
			if ReadIndex >= CompressedSize then break end

			local Value: number = buffer.readu8(CompressedBuffer, ReadIndex)
			ReadIndex += 1

			local EndIndex: number = math.min(WriteIndex + RunLength, ExpectedSize)
			for i = WriteIndex, EndIndex - 1 do
				buffer.writeu8(Result, i, Value)
			end
			WriteIndex = EndIndex
		else
			if WriteIndex < ExpectedSize then
				buffer.writeu8(Result, WriteIndex, ControlByte)
				WriteIndex += 1
			end
		end
	end

	if WriteIndex > 0 and WriteIndex < ExpectedSize then
		local LastValue: number = buffer.readu8(Result, WriteIndex - 1)
		for i = WriteIndex, ExpectedSize - 1 do
			buffer.writeu8(Result, i, LastValue)
		end
	end

	return Result
end

local function CompressVideoDataUltra(VideoData: FileStreaming.Video): { buffer }
	local PaletteCount: number = #VideoData.Palette
	local FramePixelCount: number = VideoData.Width * VideoData.Height

	local HeaderBuffer: buffer = buffer.create(20)
	buffer.writeu32(HeaderBuffer, 0, VideoData.Width)
	buffer.writeu32(HeaderBuffer, 4, VideoData.Height)
	buffer.writeu32(HeaderBuffer, 8, VideoData.FrameCount)
	buffer.writeu32(HeaderBuffer, 12, VideoData.FPS)
	buffer.writeu32(HeaderBuffer, 16, PaletteCount)

	local PaletteBuffer: buffer = buffer.create(PaletteCount * 3)
	for PaletteIndex = 1, PaletteCount do
		local PaletteColor: buffer = VideoData.Palette[PaletteIndex]
		local BaseOffset: number = (PaletteIndex - 1) * 3
		buffer.writeu8(PaletteBuffer, BaseOffset, buffer.readu8(PaletteColor, 0))
		buffer.writeu8(PaletteBuffer, BaseOffset + 1, buffer.readu8(PaletteColor, 1))
		buffer.writeu8(PaletteBuffer, BaseOffset + 2, buffer.readu8(PaletteColor, 2))
	end

	local CompressedFrameBuffers: { buffer } = {}
	for FrameIndex = 1, VideoData.FrameCount do
		local FrameBuffer: buffer = VideoData.Frames[FrameIndex]
		local ActualFrameSize: number = buffer.len(FrameBuffer)

		if ActualFrameSize ~= FramePixelCount then
			warn(
				string.format(
					"Frame %d has incorrect size: %d vs expected %d",
					FrameIndex,
					ActualFrameSize,
					FramePixelCount
				)
			)
		end

		CompressedFrameBuffers[FrameIndex] = CompressBufferRLE(FrameBuffer, FramePixelCount)
	end

	local CompressedAlphaBuffers: { buffer } = {}
	for AlphaIndex = 1, VideoData.FrameCount do
		local AlphaBuffer: buffer = VideoData.Alphas[AlphaIndex]
		local ActualAlphaSize: number = buffer.len(AlphaBuffer)

		if ActualAlphaSize ~= FramePixelCount then
			warn(
				string.format(
					"Alpha %d has incorrect size: %d vs expected %d",
					AlphaIndex,
					ActualAlphaSize,
					FramePixelCount
				)
			)
		end

		CompressedAlphaBuffers[AlphaIndex] = CompressBufferRLE(AlphaBuffer, FramePixelCount)
	end

	local AllBuffers: { buffer } = { HeaderBuffer, PaletteBuffer }
	local BufferCount: number = 2

	for FrameIndex = 1, #CompressedFrameBuffers do
		BufferCount += 1
		AllBuffers[BufferCount] = CompressedFrameBuffers[FrameIndex]
	end

	for AlphaIndex = 1, #CompressedAlphaBuffers do
		BufferCount += 1
		AllBuffers[BufferCount] = CompressedAlphaBuffers[AlphaIndex]
	end

	local TotalSize: number = 0
	for i = 1, BufferCount do
		TotalSize += buffer.len(AllBuffers[i])
	end

	local Chunks: { buffer } = {}
	local CurrentChunk: buffer = buffer.create(CHUNK_SIZE)
	local CurrentChunkSize: number = 0
	local ChunkIndex: number = 1

	for BufferIndex = 1, BufferCount do
		local CurrentBuffer: buffer = AllBuffers[BufferIndex]
		local BufferSize: number = buffer.len(CurrentBuffer)

		if CurrentChunkSize + BufferSize > CHUNK_SIZE and CurrentChunkSize > 0 then
			local FinalChunk: buffer = buffer.create(CurrentChunkSize)
			buffer.copy(FinalChunk, 0, CurrentChunk, 0, CurrentChunkSize)
			Chunks[ChunkIndex] = FinalChunk
			ChunkIndex += 1

			CurrentChunk = buffer.create(CHUNK_SIZE)
			CurrentChunkSize = 0
		end

		buffer.copy(CurrentChunk, CurrentChunkSize, CurrentBuffer, 0, BufferSize)
		CurrentChunkSize += BufferSize
	end

	if CurrentChunkSize > 0 then
		local FinalChunk: buffer = buffer.create(CurrentChunkSize)
		buffer.copy(FinalChunk, 0, CurrentChunk, 0, CurrentChunkSize)
		Chunks[ChunkIndex] = FinalChunk
	end

	return Chunks
end

local function DecompressVideoDataUltra(Chunks: { buffer }): FileStreaming.Video
	local TotalSize: number = 0
	for i = 1, #Chunks do
		TotalSize += buffer.len(Chunks[i])
	end

	if TotalSize < 20 then
		warn("Invalid compressed data: insufficient header size")
		return {
			Width = 1,
			Height = 1,
			FrameCount = 1,
			FPS = 1,
			Palette = { buffer.create(3) },
			Frames = { buffer.create(1) },
			Alphas = { buffer.create(1) },
		}
	end

	local CombinedBuffer: buffer = buffer.create(TotalSize)
	local WriteOffset: number = 0
	for i = 1, #Chunks do
		local ChunkBuffer: buffer = Chunks[i]
		local ChunkSize: number = buffer.len(ChunkBuffer)
		buffer.copy(CombinedBuffer, WriteOffset, ChunkBuffer, 0, ChunkSize)
		WriteOffset += ChunkSize
	end

	local Width: number = buffer.readu32(CombinedBuffer, 0)
	local Height: number = buffer.readu32(CombinedBuffer, 4)
	local FrameCount: number = buffer.readu32(CombinedBuffer, 8)
	local FPS: number = buffer.readu32(CombinedBuffer, 12)
	local PaletteCount: number = buffer.readu32(CombinedBuffer, 16)

	local ReadOffset: number = 20
	local FramePixelCount: number = Width * Height

	local Palette: { buffer } = {}
	for i = 1, PaletteCount do
		local PaletteBuffer: buffer = buffer.create(3)
		buffer.writeu8(PaletteBuffer, 0, buffer.readu8(CombinedBuffer, ReadOffset))
		buffer.writeu8(PaletteBuffer, 1, buffer.readu8(CombinedBuffer, ReadOffset + 1))
		buffer.writeu8(PaletteBuffer, 2, buffer.readu8(CombinedBuffer, ReadOffset + 2))
		ReadOffset += 3
		Palette[i] = PaletteBuffer
	end

	local FrameBuffers: { buffer } = {}
	local CurrentOffset: number = ReadOffset

	for FrameIndex = 1, FrameCount do
		local FrameStartOffset: number = CurrentOffset
		local TempOffset: number = CurrentOffset
		local DecodedPixels: number = 0

		while DecodedPixels < FramePixelCount and TempOffset < TotalSize - 1 do
			local ControlByte: number = buffer.readu8(CombinedBuffer, TempOffset)
			TempOffset += 1

			if bit32.band(ControlByte, 0x80) ~= 0 then
				local RunLength: number = bit32.band(ControlByte, 0x7F) + 3
				TempOffset += 1
				DecodedPixels += RunLength
			else
				DecodedPixels += 1
			end
		end

		local CompressedFrameSize: number = TempOffset - FrameStartOffset
		local CompressedFrameBuffer: buffer = buffer.create(CompressedFrameSize)
		buffer.copy(CompressedFrameBuffer, 0, CombinedBuffer, FrameStartOffset, CompressedFrameSize)

		FrameBuffers[FrameIndex] = DecompressBufferRLE(CompressedFrameBuffer, FramePixelCount, 0)
		CurrentOffset = TempOffset
	end

	local AlphaBuffers: { buffer } = {}
	for AlphaIndex = 1, FrameCount do
		local AlphaStartOffset: number = CurrentOffset
		local TempOffset: number = CurrentOffset
		local DecodedPixels: number = 0

		while DecodedPixels < FramePixelCount and TempOffset < TotalSize - 1 do
			local ControlByte: number = buffer.readu8(CombinedBuffer, TempOffset)
			TempOffset += 1

			if bit32.band(ControlByte, 0x80) ~= 0 then
				local RunLength: number = bit32.band(ControlByte, 0x7F) + 3
				TempOffset += 1
				DecodedPixels += RunLength
			else
				DecodedPixels += 1
			end
		end

		local CompressedAlphaSize: number = TempOffset - AlphaStartOffset
		local CompressedAlphaBuffer: buffer = buffer.create(CompressedAlphaSize)
		buffer.copy(CompressedAlphaBuffer, 0, CombinedBuffer, AlphaStartOffset, CompressedAlphaSize)

		AlphaBuffers[AlphaIndex] = DecompressBufferRLE(CompressedAlphaBuffer, FramePixelCount, 255)
		CurrentOffset = TempOffset
	end

	return {
		Width = Width,
		Height = Height,
		FrameCount = FrameCount,
		FPS = FPS,
		Palette = Palette,
		Frames = FrameBuffers,
		Alphas = AlphaBuffers,
	}
end

local function ParseFromHost(Video: string): FileStreaming.Video?
	local VideoData: FileStreaming.Video? = FileStreaming.GetVideoDataAsync(Video)
	if not VideoData then return nil end

	local Chunks: { buffer } = CompressVideoDataUltra(VideoData)

	local ChunkCountSuccess: boolean = pcall(DataStore.SetAsync, DataStore, Video .. "_chunks", #Chunks)
	if not ChunkCountSuccess then warn(string.format("Failed to save chunk count for video %s", Video)) end

	local Success: boolean = true
	local FailedChunks: { number } = {}

	for ChunkIndex = 1, #Chunks do
		local ChunkKey: string = Video .. "_chunk_" .. tostring(ChunkIndex)
		local ChunkBuffer: buffer = Chunks[ChunkIndex]

		local ChunkData: string = EncodeBufferToBase64(ChunkBuffer)
		local ChunkSuccess: boolean = pcall(DataStore.SetAsync, DataStore, ChunkKey, ChunkData)

		if not ChunkSuccess then
			FailedChunks[#FailedChunks + 1] = ChunkIndex
			Success = false
			warn(string.format("Failed to save chunk %d for video %s", ChunkIndex, Video))
		end
	end

	VideoCache[Video] = VideoData

	if not Success then
		warn(
			string.format(
				"Partial failure storing video %s. Failed chunks: %s",
				Video,
				table.concat(FailedChunks, ", ")
			)
		)
	end

	return VideoData
end

function VideoParser.ParseVideo(Video: string): FileStreaming.Video?
	if VideoCache[Video] then return VideoCache[Video] end

	local ChunkCountSuccess: boolean, ChunkCount: number = pcall(DataStore.GetAsync, DataStore, Video .. "_chunks")
	if not ChunkCountSuccess or not ChunkCount or ChunkCount <= 0 then return ParseFromHost(Video) end

	local Chunks: { buffer } = {}
	local LoadSuccess: boolean = true
	local MissingChunks: { number } = {}

	for ChunkIndex = 1, ChunkCount do
		local ChunkKey: string = Video .. "_chunk_" .. tostring(ChunkIndex)
		local ChunkSuccess: boolean, ChunkData: string = pcall(DataStore.GetAsync, DataStore, ChunkKey)

		if ChunkSuccess and ChunkData and string.len(ChunkData) > 0 then
			local ChunkBuffer: buffer = DecodeBase64ToBuffer(ChunkData)
			Chunks[ChunkIndex] = ChunkBuffer
		else
			MissingChunks[#MissingChunks + 1] = ChunkIndex
			LoadSuccess = false
			warn(string.format("Failed to load chunk %d for video %s", ChunkIndex, Video))
		end
	end

	if not LoadSuccess then
		warn(
			string.format(
				"Missing chunks for video %s: %s. Falling back to host parsing.",
				Video,
				table.concat(MissingChunks, ", ")
			)
		)
		return ParseFromHost(Video)
	end

	local VideoData: FileStreaming.Video = DecompressVideoDataUltra(Chunks)

	VideoCache[Video] = VideoData
	return VideoData
end

function VideoParser.ClearCache(): ()
	VideoCache = {}
end

function VideoParser.GetCacheInfo(): { [string]: boolean }
	local CacheInfo: { [string]: boolean } = {}
	for VideoName: string, _ in VideoCache do
		CacheInfo[VideoName] = true
	end
	return CacheInfo
end

return VideoParser
