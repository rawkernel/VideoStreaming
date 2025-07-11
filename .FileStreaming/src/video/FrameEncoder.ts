interface ConvertOptions {
  width: number;
  height: number;
  fps: number;
  paletteSize: number;
}

export class FrameEncoder {
  static encode(
    frames: number[][],
    palette: number[][],
    alphaPixels: number[],
    options: ConvertOptions
  ): Buffer {
    // 1) pad / truncate palette
    while (palette.length < options.paletteSize) palette.push([0, 0, 0]);
    if (palette.length > options.paletteSize) palette = palette.slice(0, options.paletteSize);

    // 2) header (6 bytes)
    const header = Buffer.alloc(6);
    header.writeUInt16LE(options.width, 0);
    header.writeUInt16LE(options.height, 2);
    header.writeUInt8(options.paletteSize, 4);
    header.writeUInt8(frames.length, 5);

    // 3) palette RGB triplets
    const paletteBuf = Buffer.alloc(options.paletteSize * 3);
    palette.forEach(([r, g, b], i) => {
      paletteBuf.writeUInt8(r & 0xff, i * 3);
      paletteBuf.writeUInt8(g & 0xff, i * 3 + 1);
      paletteBuf.writeUInt8(b & 0xff, i * 3 + 2);
    });

    // 4) frames: each is array of palette indices (1 byte each)
    const framesBuf = Buffer.concat(frames.map((f) => Buffer.from(f)));

    // 5) alpha: 1 byte per pixel for ALL frames
    const alphaBuf = Buffer.alloc(alphaPixels.length);
    alphaPixels.forEach((a, i) => alphaBuf.writeUInt8(a & 0xff, i));

    return Buffer.concat([header, paletteBuf, framesBuf, alphaBuf]);
  }
}
