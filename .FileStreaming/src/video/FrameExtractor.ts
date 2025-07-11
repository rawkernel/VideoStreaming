// src/video/FrameExtractor.ts
import gifFrames from 'gif-frames';
import sharp from 'sharp';
import { Readable } from 'stream';

interface ExtractOptions {
  width: number;
  height: number;
  fps: number;
}

function streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('end', () => resolve(Buffer.concat(chunks)));
    stream.on('error', reject);
  });
}

export class FrameExtractor {
  static async extract(gifPath: string, { width, height, fps }: ExtractOptions): Promise<Buffer[]> {
    const all = await gifFrames({
      url: gifPath,
      frames: 'all',
      outputType: 'png',
      cumulative: true,
    });

    // pick roughly fps frames evenly
    const step = Math.max(1, Math.floor(all.length / fps));
    const sel = all.filter((_, i) => i % step === 0).slice(0, fps);

    // decode & resize each to a pure RGBA Buffer
    return Promise.all(sel.map(async (f) => {
      const pngStream = await f.getImage();
      const raw = await streamToBuffer(pngStream);
      return sharp(raw).resize(width, height).png().toBuffer();
    }));
  }
}
