import { describe, expect, test } from 'bun:test';
import { extractPage, cleanNunJunk, hasDottedNun } from '../src/lib/reflow';

const H = 11;
const item = (str: string, x: number, w: number, y = 700) => ({ str, width: w, height: H, transform: [H, 0, 0, H, x, y], hasEOL: false });
const doc = (items: any[]) => ({
  getPage: async () => ({ getViewport: () => ({ width: 600, height: 800 }), getTextContent: async () => ({ items }), cleanup() {} }),
});
const text = async (items: any[]) => (await extractPage(doc(items), 1)).paras.map((p) => p.text).join('\n');

describe('reflow: Arabic repairs', () => {
  test('a stretch glyph sharing x with its neighbour still joins the word', async () => {
    // right to left: المرخ | (stretch) | ص | إلغاء ; the stretch is listed before its neighbour and slightly higher
    const t = await text([
      item('\u0085', 400, 0, 700.05), item('المرخ', 400, 40), item('ص', 360 - 6, 8), item('إلغاء', 300, 30),
    ]);
    expect(t).toContain('المرخص');
  });
  test('a lone letter is glued to the nearer neighbour, و is left alone', async () => {
    const t = await text([item('كن', 400, 14), item('ت', 391, 6), item('تتساءل', 344, 40), item('و', 330, 6), item('نعم', 300, 20)]);
    expect(t).toContain('كنت');
    expect(t).toContain('تتساءل');
  });
  test('dotted nun items', async () => {
    const t = await text([item('يمك', 400, 20), item('نNِّ', 392, 0), item('ني', 380, 10)]);
    expect(t).not.toMatch(/[\u064B-\u0652]/);
    expect(t).toContain('يمكنني');
  });
  test('text-level cleanup', () => {
    expect(cleanNunJunk('يمك نِّني')).toBe('يمكنني');
    expect(cleanNunJunk('أ نَك')).toBe('أ نك');
    expect(cleanNunJunk('برنامجِّنا')).toBe('برنامجنا');
    expect(cleanNunJunk('لاحظ أن نِّا')).toBe('لاحظ أننا');
    expect(hasDottedNun([item('نِّ', 1, 0)])).toBe(true);
    expect(hasDottedNun([item('نِّ', 1, 5)])).toBe(false);
  });
});
