import { FrameExtractor } from './FrameExtractor';
import { FrameEncoder } from './FrameEncoder';
import { PaletteQuantizer } from './PaletteQuantizer';

interface ConvertOptions {
  width: number;
  height: number;
  fps: number;
  paletteSize: number;
}

export class GifConverter {
  constructor(private readonly gifPath: string, private readonly opts: ConvertOptions) {}

  async convert(): Promise<Buffer> {
    const frames = await FrameExtractor.extract(this.gifPath, this.opts);
    const { palette, indexedFrames, alphaPixels } = await PaletteQuantizer.quantize(
      frames,
      this.opts.paletteSize
    );
    return FrameEncoder.encode(indexedFrames, palette, alphaPixels, this.opts);
  }
}
