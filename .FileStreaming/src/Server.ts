import express from 'express';
import path from 'path';
import { GifConverter } from './video/GifConverter';

const app = express();
const PORT = 8080;

app.get('/video', async (req, res) => {
  try {
    const file = String(req.query.file);
    const gifPath = path.resolve(__dirname, '../assets', file);

    const converter = new GifConverter(gifPath, {
      width: 255,
      height: 255,
      fps: 60,
      paletteSize: 64,
    });
    const data = await converter.convert();

    res.setHeader('Content-Type', 'application/octet-stream');
    res.send(data);
  } catch (err) {
    console.error(err);
    res.status(500).send('Error');
  }
});

app.listen(PORT, () => console.log(`🚀 Running at http://localhost:${PORT}`));
