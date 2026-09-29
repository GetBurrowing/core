// Decodes the 8-bit PNG a CDP screenshot returns into raw RGBA bytes.
// No colour management: the bytes read here are the bytes Chrome wrote,
// which is the point. Handles colour types 2 (RGB) and 6 (RGBA), 8-bit,
// non-interlaced, which is what Page.captureScreenshot emits.
import { inflateSync } from "node:zlib";

export function decodePng(buf) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  sig.forEach((b, i) => {
    if (buf[i] !== b) throw new Error("not a PNG");
  });

  let pos = 8;
  let width, height, bitDepth, colorType, interlace;
  const idat = [];

  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString("ascii", pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    pos += 12 + len;
  }

  if (bitDepth !== 8 || interlace !== 0 || ![2, 6].includes(colorType)) {
    throw new Error(`unsupported PNG: depth ${bitDepth} type ${colorType} interlace ${interlace}`);
  }

  const bpp = colorType === 6 ? 4 : 3;
  const stride = width * bpp;
  const raw = inflateSync(Buffer.concat(idat));
  const px = Buffer.alloc(height * stride);

  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = px.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? px.subarray((y - 1) * stride, y * stride) : null;

    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[x - bpp] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      } else if (filter !== 0) throw new Error(`bad PNG filter ${filter}`);
      out[x] = v & 0xff;
    }
  }

  return {
    width,
    height,
    pixel(x, y) {
      const i = y * stride + x * bpp;
      return [px[i], px[i + 1], px[i + 2], bpp === 4 ? px[i + 3] : 255];
    },
  };
}
