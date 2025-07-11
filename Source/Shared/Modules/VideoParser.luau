--!strict
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if RunService:IsClient() then error("VideoParser must be used on the server") end

local FileStreaming = require(ReplicatedStorage.Modules.FileStreaming)

local DataStore = DataStoreService:GetDataStore("VIDEO_STREAMING")
local CHUNK_SIZE: number = 3 * 1024 * 1024 -- 3MB per chunk to stay well under limit
local MAX_RLE_COUNT: number = 255 -- Maximum run-length encoding count

local VideoParser = {}

-- Cache for storing video data in memory
local VideoCache: { [string]: FileStreaming.Video } = {}

-- Ultra-fast Base64 encoding for binary buffer data (UTF-8 safe)
local function EncodeBufferToBase64(Data: buffer): string
	local Base64Chars: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local Result: { string } = {}
	local DataLength: number = buffer.len(Data)
	local PadCount: number = (3 - (DataLength % 3)) % 3

	-- Process data in 3-byte chunks
	for ByteIndex: number = 0, DataLength - 1, 3 do
		local B1: number = buffer.readu8(Data, ByteIndex)
		local B2: number = if ByteIndex + 1 < DataLength then buffer.readu8(Data, ByteIndex + 1) else 0
		local B3: number = if ByteIndex + 2 < DataLength then buffer.readu8(Data, ByteIndex + 2) else 0

		local Combined: number = bit32.bor(bit32.lshift(B1, 16), bit32.lshift(B2, 8), B3)

		Result[#Result + 1] = string.sub(Base64Chars, bit32.rshift(Combined, 18) + 1, bit32.rshift(Combined, 18) + 1)
		Result[#Result + 1] = string.sub(
			Base64Chars,
			bit32.band(bit32.rshift(Combined, 12), 0x3F) + 1,
			bit32.band(bit32.rshift(Combined, 12), 0x3F) + 1
		)
		Result[#Result + 1] = string.sub(
			Base64Chars,
			bit32.band(bit32.rshift(Combined, 6), 0x3F) + 1,
			bit32.band(bit32.rshift(Combined, 6), 0x3F) + 1
		)
		Result[#Result + 1] = string.sub(Base64Chars, bit32.band(Combined, 0x3F) + 1, bit32.band(Combined, 0x3F) + 1)
	end

	-- Add padding
	for PadIndex: number = 1, PadCount do
		Result[#Result - PadIndex + 1] = "="
	end

	return table.concat(Result)
end

-- Ultra-fast Base64 decoding back to buffer with minimal bounds checking
local function DecodeBase64ToBuffer(Data: string): buffer
	local BASE64_DECODE: { [number]: number } = {}

	-- Pre-calculate decode table for performance
	local Base64Chars: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for Index: number = 1, 64 do
		BASE64_DECODE[string.byte(Base64Chars, Index)] = Index - 1
	end

	-- Fast path: remove padding and calculate length
	local CleanData: string = string.gsub(Data, "=", "")
	local CleanLength: number = string.len(CleanData)
	local OutputLength: number = math.floor(CleanLength * 3 / 4)

	if OutputLength <= 0 then return buffer.create(0) end

	local Result: buffer = buffer.create(OutputLength)
	local ResultIndex: number = 0
	local DataBytes: buffer = buffer.fromstring(CleanData)

	-- Ultra-fast processing using direct byte access
	for ByteIndex: number = 0, CleanLength - 4, 4 do
		local C1: number = BASE64_DECODE[buffer.readu8(DataBytes, ByteIndex)] or 0
		local C2: number = BASE64_DECODE[buffer.readu8(DataBytes, ByteIndex + 1)] or 0
		local C3: number = BASE64_DECODE[buffer.readu8(DataBytes, ByteIndex + 2)] or 0
		local C4: number = BASE64_DECODE[buffer.readu8(DataBytes, ByteIndex + 3)] or 0

		local Combined: number = bit32.bor(bit32.lshift(C1, 18), bit32.lshift(C2, 12), bit32.lshift(C3, 6), C4)

		buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 16), 0xFF))
		buffer.writeu8(Result, ResultIndex + 1, bit32.band(bit32.rshift(Combined, 8), 0xFF))
		buffer.writeu8(Result, ResultIndex + 2, bit32.band(Combined, 0xFF))
		ResultIndex += 3
	end

	-- Handle remainder (minimal bounds checking)
	local Remainder: number = CleanLength % 4
	if Remainder >= 2 and ResultIndex < OutputLength then
		local C1: number = BASE64_DECODE[buffer.readu8(DataBytes, CleanLength - Remainder)] or 0
		local C2: number = BASE64_DECODE[buffer.readu8(DataBytes, CleanLength - Remainder + 1)] or 0
		local Combined: number = bit32.bor(bit32.lshift(C1, 18), bit32.lshift(C2, 12))

		buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 16), 0xFF))
		ResultIndex += 1

		if Remainder == 3 and ResultIndex < OutputLength then
			local C3: number = BASE64_DECODE[buffer.readu8(DataBytes, CleanLength - 1)] or 0
			Combined = bit32.bor(Combined, bit32.lshift(C3, 6))
			buffer.writeu8(Result, ResultIndex, bit32.band(bit32.rshift(Combined, 8), 0xFF))
		end
	end

	return Result
end

-- Ultra-optimized buffer-based compression with aggressive RLE and bit packing
local function CompressVideoDataUltra(VideoData: FileStreaming.Video): { buffer }
	-- Calculate exact buffer sizes needed
	local PaletteCount: number = #VideoData.Palette
	local FramePixelCount: number = VideoData.Width * VideoData.Height

	-- Create header buffer with metadata
	local HeaderBuffer: buffer = buffer.create(20) -- 5 * 4 bytes for metadata
	buffer.writeu32(HeaderBuffer, 0, VideoData.Width)
	buffer.writeu32(HeaderBuffer, 4, VideoData.Height)
	buffer.writeu32(HeaderBuffer, 8, VideoData.FrameCount)
	buffer.writeu32(HeaderBuffer, 12, VideoData.FPS)
	buffer.writeu32(HeaderBuffer, 16, PaletteCount)

	-- Ultra-compress palette directly to buffer (3 bytes per color)
	local PaletteBuffer: buffer = buffer.create(PaletteCount * 3)
	local PaletteOffset: number = 0
	for PaletteIndex: number = 1, PaletteCount do
		local PaletteColor: buffer = VideoData.Palette[PaletteIndex]
		for ColorChannel: number = 0, 2 do
			buffer.writeu8(PaletteBuffer, PaletteOffset, buffer.readu8(PaletteColor, ColorChannel))
			PaletteOffset += 1
		end
	end

	-- Ultra-aggressive RLE compression for frames using bit manipulation
	local CompressedFrameBuffers: { buffer } = {}
	for FrameIndex: number = 1, VideoData.FrameCount do
		local FrameBuffer: buffer = VideoData.Frames[FrameIndex]
		local TempCompressed: { number } = {}
		local CompressedSize: number = 0

		-- Validate frame buffer size to prevent empty frames
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

		local PixelIndex: number = 0
		while PixelIndex < math.min(ActualFrameSize, FramePixelCount) do
			local CurrentValue: number = buffer.readu8(FrameBuffer, PixelIndex)
			local RunLength: number = 1

			-- Count consecutive identical values with maximum efficiency
			while PixelIndex + RunLength < math.min(ActualFrameSize, FramePixelCount) and RunLength < MAX_RLE_COUNT do
				if buffer.readu8(FrameBuffer, PixelIndex + RunLength) == CurrentValue then
					RunLength += 1
				else
					break
				end
			end

			-- Pack run-length and value using bit operations for maximum density
			if RunLength >= 3 then
				-- Use RLE: bit pattern 1xxxxxxx for run length, followed by value
				TempCompressed[CompressedSize + 1] = bit32.bor(0x80, RunLength - 3) -- 0x80 = RLE flag
				TempCompressed[CompressedSize + 2] = CurrentValue
				CompressedSize += 2
			else
				-- Store raw values for short runs: bit pattern 0xxxxxxx
				for RunIndex: number = 0, RunLength - 1 do
					TempCompressed[CompressedSize + 1] = CurrentValue
					CompressedSize += 1
				end
			end

			PixelIndex += RunLength
		end

		-- Ensure we have at least some compressed data to prevent empty frames
		if CompressedSize == 0 then
			warn(string.format("Frame %d resulted in empty compression, adding default pixel", FrameIndex))
			TempCompressed[1] = 0 -- Add a single black pixel
			CompressedSize = 1
		end

		-- Create optimally sized buffer for compressed frame
		local CompressedFrameBuffer: buffer = buffer.create(CompressedSize)
		for ByteIndex: number = 1, CompressedSize do
			buffer.writeu8(CompressedFrameBuffer, ByteIndex - 1, TempCompressed[ByteIndex])
		end
		CompressedFrameBuffers[FrameIndex] = CompressedFrameBuffer
	end

	-- Ultra-aggressive RLE compression for alpha channels
	local CompressedAlphaBuffers: { buffer } = {}
	for AlphaIndex: number = 1, VideoData.FrameCount do
		local AlphaBuffer: buffer = VideoData.Alphas[AlphaIndex]
		local TempCompressed: { number } = {}
		local CompressedSize: number = 0

		-- Validate alpha buffer size to prevent empty alpha channels
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

		local PixelIndex: number = 0
		while PixelIndex < math.min(ActualAlphaSize, FramePixelCount) do
			local CurrentValue: number = buffer.readu8(AlphaBuffer, PixelIndex)
			local RunLength: number = 1

			-- Count consecutive identical values with maximum efficiency
			while PixelIndex + RunLength < math.min(ActualAlphaSize, FramePixelCount) and RunLength < MAX_RLE_COUNT do
				if buffer.readu8(AlphaBuffer, PixelIndex + RunLength) == CurrentValue then
					RunLength += 1
				else
					break
				end
			end

			-- Pack run-length and value using bit operations for maximum density
			if RunLength >= 3 then
				-- Use RLE: bit pattern 1xxxxxxx for run length, followed by value
				TempCompressed[CompressedSize + 1] = bit32.bor(0x80, RunLength - 3) -- 0x80 = RLE flag
				TempCompressed[CompressedSize + 2] = CurrentValue
				CompressedSize += 2
			else
				-- Store raw values for short runs: bit pattern 0xxxxxxx
				for RunIndex: number = 0, RunLength - 1 do
					TempCompressed[CompressedSize + 1] = CurrentValue
					CompressedSize += 1
				end
			end

			PixelIndex += RunLength
		end

		-- Ensure we have at least some compressed data to prevent empty alpha channels
		if CompressedSize == 0 then
			warn(string.format("Alpha %d resulted in empty compression, adding default alpha", AlphaIndex))
			TempCompressed[1] = 255 -- Add full opacity as default
			CompressedSize = 1
		end

		-- Create optimally sized buffer for compressed alpha
		local CompressedAlphaBuffer: buffer = buffer.create(CompressedSize)
		for ByteIndex: number = 1, CompressedSize do
			buffer.writeu8(CompressedAlphaBuffer, ByteIndex - 1, TempCompressed[ByteIndex])
		end
		CompressedAlphaBuffers[AlphaIndex] = CompressedAlphaBuffer
	end

	-- Combine all buffers into chunks for DataStore storage
	local AllBuffers: { buffer } = { HeaderBuffer, PaletteBuffer }
	for FrameIndex: number = 1, #CompressedFrameBuffers do
		AllBuffers[#AllBuffers + 1] = CompressedFrameBuffers[FrameIndex]
	end
	for AlphaIndex: number = 1, #CompressedAlphaBuffers do
		AllBuffers[#AllBuffers + 1] = CompressedAlphaBuffers[AlphaIndex]
	end

	-- Calculate total size and create chunk information
	local TotalSize: number = 0
	for BufferIndex: number = 1, #AllBuffers do
		TotalSize += buffer.len(AllBuffers[BufferIndex])
	end

	-- Split into chunks if necessary
	local Chunks: { buffer } = {}
	local CurrentChunk: buffer = buffer.create(CHUNK_SIZE)
	local CurrentChunkSize: number = 0
	local ChunkIndex: number = 1

	for BufferIndex: number = 1, #AllBuffers do
		local CurrentBuffer: buffer = AllBuffers[BufferIndex]
		local BufferSize: number = buffer.len(CurrentBuffer)

		-- If buffer doesn't fit in current chunk, finalize current and start new
		if CurrentChunkSize + BufferSize > CHUNK_SIZE and CurrentChunkSize > 0 then
			-- Resize current chunk to actual size used
			local FinalChunk: buffer = buffer.create(CurrentChunkSize)
			buffer.copy(FinalChunk, 0, CurrentChunk, 0, CurrentChunkSize)
			Chunks[ChunkIndex] = FinalChunk
			ChunkIndex += 1

			-- Start new chunk
			CurrentChunk = buffer.create(CHUNK_SIZE)
			CurrentChunkSize = 0
		end

		-- Copy buffer to current chunk
		buffer.copy(CurrentChunk, CurrentChunkSize, CurrentBuffer, 0, BufferSize)
		CurrentChunkSize += BufferSize
	end

	-- Finalize last chunk
	if CurrentChunkSize > 0 then
		local FinalChunk: buffer = buffer.create(CurrentChunkSize)
		buffer.copy(FinalChunk, 0, CurrentChunk, 0, CurrentChunkSize)
		Chunks[ChunkIndex] = FinalChunk
	end

	return Chunks
end

-- Lightning-fast buffer-based decompression with minimal safety overhead
local function DecompressVideoDataUltra(Chunks: { buffer }): FileStreaming.Video
	-- Combine all chunks into single buffer for processing
	local TotalSize: number = 0
	for ChunkIndex: number = 1, #Chunks do
		TotalSize += buffer.len(Chunks[ChunkIndex])
	end

	-- Basic validation only
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
	local CombinedOffset: number = 0
	for ChunkIndex: number = 1, #Chunks do
		local ChunkBuffer: buffer = Chunks[ChunkIndex]
		local ChunkSize: number = buffer.len(ChunkBuffer)
		buffer.copy(CombinedBuffer, CombinedOffset, ChunkBuffer, 0, ChunkSize)
		CombinedOffset += ChunkSize
	end

	-- Read header metadata (trust the data for speed)
	local Width: number = buffer.readu32(CombinedBuffer, 0)
	local Height: number = buffer.readu32(CombinedBuffer, 4)
	local FrameCount: number = buffer.readu32(CombinedBuffer, 8)
	local FPS: number = buffer.readu32(CombinedBuffer, 12)
	local PaletteCount: number = buffer.readu32(CombinedBuffer, 16)

	local ReadOffset: number = 20 -- Start after header
	local FramePixelCount: number = Width * Height

	-- Lightning-fast palette decompression
	local Palette: { [number]: buffer } = {}
	for PaletteIndex: number = 1, PaletteCount do
		local PaletteBuffer: buffer = buffer.create(3)
		buffer.writeu8(PaletteBuffer, 0, buffer.readu8(CombinedBuffer, ReadOffset))
		buffer.writeu8(PaletteBuffer, 1, buffer.readu8(CombinedBuffer, ReadOffset + 1))
		buffer.writeu8(PaletteBuffer, 2, buffer.readu8(CombinedBuffer, ReadOffset + 2))
		ReadOffset += 3
		Palette[PaletteIndex] = PaletteBuffer
	end

	-- Lightning-fast frame decompression with minimal bounds checking
	local Frames: { [number]: buffer } = {}
	for FrameIndex: number = 1, FrameCount do
		local FrameBuffer: buffer = buffer.create(FramePixelCount)
		local PixelIndex: number = 0

		-- Initialize frame buffer to prevent flashing from incomplete data
		for InitIndex: number = 0, FramePixelCount - 1 do
			buffer.writeu8(FrameBuffer, InitIndex, 0)
		end

		-- Process frame data as fast as possible
		while PixelIndex < FramePixelCount and ReadOffset < TotalSize - 1 do
			local ControlByte: number = buffer.readu8(CombinedBuffer, ReadOffset)
			ReadOffset += 1

			-- Check RLE flag using bit operations
			if bit32.band(ControlByte, 0x80) ~= 0 then
				-- RLE encoded data
				local RunLength: number = bit32.band(ControlByte, 0x7F) + 3
				local Value: number = buffer.readu8(CombinedBuffer, ReadOffset)
				ReadOffset += 1

				-- Ultra-fast RLE write loop with bounds checking
				local EndPixel: number = math.min(PixelIndex + RunLength, FramePixelCount)
				for WriteIndex: number = PixelIndex, EndPixel - 1 do
					buffer.writeu8(FrameBuffer, WriteIndex, Value)
				end
				PixelIndex = EndPixel
			else
				-- Raw value with bounds checking
				if PixelIndex < FramePixelCount then
					buffer.writeu8(FrameBuffer, PixelIndex, ControlByte)
					PixelIndex += 1
				end
			end
		end

		-- Ensure frame is complete - fill any remaining pixels with the last value
		if PixelIndex > 0 and PixelIndex < FramePixelCount then
			local LastValue: number = buffer.readu8(FrameBuffer, PixelIndex - 1)
			for FillIndex: number = PixelIndex, FramePixelCount - 1 do
				buffer.writeu8(FrameBuffer, FillIndex, LastValue)
			end
		end

		Frames[FrameIndex] = FrameBuffer
	end

	-- Lightning-fast alpha decompression with minimal bounds checking
	local Alphas: { [number]: buffer } = {}
	for AlphaIndex: number = 1, FrameCount do
		local AlphaBuffer: buffer = buffer.create(FramePixelCount)
		local PixelIndex: number = 0

		-- Initialize alpha buffer to full opacity to prevent flashing
		for InitIndex: number = 0, FramePixelCount - 1 do
			buffer.writeu8(AlphaBuffer, InitIndex, 255)
		end

		-- Process alpha data as fast as possible
		while PixelIndex < FramePixelCount and ReadOffset < TotalSize - 1 do
			local ControlByte: number = buffer.readu8(CombinedBuffer, ReadOffset)
			ReadOffset += 1

			-- Check RLE flag using bit operations
			if bit32.band(ControlByte, 0x80) ~= 0 then
				-- RLE encoded data
				local RunLength: number = bit32.band(ControlByte, 0x7F) + 3
				local Value: number = buffer.readu8(CombinedBuffer, ReadOffset)
				ReadOffset += 1

				-- Ultra-fast RLE write loop with bounds checking
				local EndPixel: number = math.min(PixelIndex + RunLength, FramePixelCount)
				for WriteIndex: number = PixelIndex, EndPixel - 1 do
					buffer.writeu8(AlphaBuffer, WriteIndex, Value)
				end
				PixelIndex = EndPixel
			else
				-- Raw value with bounds checking
				if PixelIndex < FramePixelCount then
					buffer.writeu8(AlphaBuffer, PixelIndex, ControlByte)
					PixelIndex += 1
				end
			end
		end

		-- Ensure alpha is complete - fill any remaining pixels with full opacity
		if PixelIndex < FramePixelCount then
			for FillIndex: number = PixelIndex, FramePixelCount - 1 do
				buffer.writeu8(AlphaBuffer, FillIndex, 255)
			end
		end

		Alphas[AlphaIndex] = AlphaBuffer
	end

	return {
		Width = Width,
		Height = Height,
		FrameCount = FrameCount,
		FPS = FPS,
		Palette = Palette,
		Frames = Frames,
		Alphas = Alphas,
	}
end

-- Ultra-optimized video parsing with multi-key DataStore support
local function ParseFromHost(Video: string): FileStreaming.Video?
	local VideoData: FileStreaming.Video? = FileStreaming.GetVideoDataAsync(Video)
	if not VideoData then return nil end

	-- Use ultra-compression to create buffer chunks
	local Chunks: { buffer } = CompressVideoDataUltra(VideoData)

	-- Calculate total compressed size
	local TotalCompressedSize: number = 0
	for ChunkIndex: number = 1, #Chunks do
		TotalCompressedSize += buffer.len(Chunks[ChunkIndex])
	end

	-- Store chunks in DataStore with optimized error handling
	local Success: boolean = true
	local FailedChunks: { number } = {}

	-- Store chunk count first
	local ChunkCountSuccess: boolean = pcall(DataStore.SetAsync, DataStore, Video .. "_chunks", #Chunks)
	if not ChunkCountSuccess then
		warn(string.format("Failed to save chunk count for video %s", Video))
		Success = false
	end

	-- Store each chunk with parallel processing simulation (sequential but optimized)
	for ChunkIndex: number = 1, #Chunks do
		local ChunkKey: string = Video .. "_chunk_" .. tostring(ChunkIndex)
		local ChunkBuffer: buffer = Chunks[ChunkIndex]

		-- Convert buffer to Base64 string for UTF-8 safe DataStore storage
		local ChunkData: string = EncodeBufferToBase64(ChunkBuffer)
		local ChunkSuccess: boolean = pcall(DataStore.SetAsync, DataStore, ChunkKey, ChunkData)

		if not ChunkSuccess then
			FailedChunks[#FailedChunks + 1] = ChunkIndex
			Success = false
			warn(string.format("Failed to save chunk %d for video %s", ChunkIndex, Video))
		end
	end

	if Success then
		VideoCache[Video] = VideoData
	else
		warn(
			string.format(
				"Partial failure storing video %s. Failed chunks: %s",
				Video,
				table.concat(FailedChunks, ", ")
			)
		)
		-- Still cache the video data for immediate use
		VideoCache[Video] = VideoData
	end

	return VideoData
end

function VideoParser.ParseVideo(Video: string): FileStreaming.Video?
	-- Check cache first for maximum performance
	if VideoCache[Video] then return VideoCache[Video] end

	-- Try to load from DataStore with optimized multi-key retrieval

	-- Try to load from DataStore with ultra-optimized multi-key retrieval
	local ChunkCountSuccess: boolean, ChunkCount: number = pcall(DataStore.GetAsync, DataStore, Video .. "_chunks")
	if not ChunkCountSuccess or not ChunkCount or ChunkCount <= 0 then return ParseFromHost(Video) end

	-- Load all chunks with optimized error handling
	local Chunks: { buffer } = {}
	local LoadSuccess: boolean = true
	local MissingChunks: { number } = {}

	for ChunkIndex: number = 1, ChunkCount do
		local ChunkKey: string = Video .. "_chunk_" .. tostring(ChunkIndex)
		local ChunkSuccess: boolean, ChunkData: string = pcall(DataStore.GetAsync, DataStore, ChunkKey)

		if ChunkSuccess and ChunkData and string.len(ChunkData) > 0 then
			-- Convert Base64 string back to buffer
			local ChunkBuffer: buffer = DecodeBase64ToBuffer(ChunkData)
			Chunks[ChunkIndex] = ChunkBuffer
		else
			MissingChunks[#MissingChunks + 1] = ChunkIndex
			LoadSuccess = false
			warn(string.format("Failed to load chunk %d for video %s", ChunkIndex, Video))
		end
	end

	-- If any chunks are missing, fall back to host parsing
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

	-- Decompress using lightning-fast decompression
	local VideoData: FileStreaming.Video = DecompressVideoDataUltra(Chunks)

	-- Cache the result for future use
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
