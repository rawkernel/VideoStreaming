import quantize from 'quantize';
import { PNG } from 'pngjs';

type RGB = [number, number, number];

function nearestColorIndex(palette: number[][], r: number, g: number, b: number): number {
  let minDist = Infinity;
  let index = 0;
  for (let i = 0; i < palette.length; i++) {
    const [pr, pg, pb] = palette[i];
    const dist = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2;
    if (dist < minDist) {
      minDist = dist;
      index = i;
    }
  }
  return index;
}

function clampColor([r, g, b]: number[]): [number, number, number] {
  return [
    Math.min(255, Math.max(0, r)),
    Math.min(255, Math.max(0, g)),
    Math.min(255, Math.max(0, b)),
  ];
}

export class PaletteQuantizer {
  static async quantize(buffers: Buffer[], paletteSize: number) {
    const allPixels: RGB[] = [];
    const alphaPixels: number[] = [];
    const images = buffers.map((b) => PNG.sync.read(b));

    for (let frameIndex = 0; frameIndex < images.length; frameIndex++) {
      const img = images[frameIndex];
      for (let i = 0; i < img.data.length; i += 4) {
        const r = img.data[i];
        const g = img.data[i + 1];
        const b = img.data[i + 2];
        const a = img.data[i + 3];
        allPixels.push([r, g, b]);
        alphaPixels.push(a);
      }
    }

    const cmap = quantize(allPixels, paletteSize);
    if (!cmap) throw new Error('Quantization failed');

    const rawPalette = cmap.palette();
    const palette = rawPalette.map(clampColor);

    const indexedFrames = images.map((img, frameIndex) => {
      const w = img.width * img.height;
      const idxs = new Array<number>(w);
      for (let i = 0; i < w; i++) {
        const base = i * 4;
        const [r, g, b] = [img.data[base], img.data[base + 1], img.data[base + 2]];
        const j = nearestColorIndex(palette, r, g, b);
        idxs[i] = j >= 0 ? j : 0;
      }

      return idxs;
    });

    return { palette, indexedFrames, alphaPixels };
  }
}
