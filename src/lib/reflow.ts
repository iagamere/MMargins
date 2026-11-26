/* Turns a PDF page's positioned text fragments into readable paragraphs.
   This is a heuristic reconstruction: it is intentionally conservative and never touches OCR. */

export interface Para {
  text: string;
  kind: 'p' | 'h';
  rtl: boolean;
}
export interface PageText {
  paras: Para[];
  chars: number;
  endsOpen: boolean;
  /** diagnostics: unusual code points found in the raw page text, e.g. "E001×3 064E×12" */
  odd?: string;
}

const RTL_RE = /[֐-ࣿיִ-﷿ﹰ-﻿]/g;
const LTR_RE = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ]/g;
/** Arabic combining marks (harakat, shadda, sukun, tanwin, dagger alef, Quranic signs). */
const MARK_ONLY = /^[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E4\u06E7\u06E8\u06EA-\u06ED\u08D3-\u08FF]+$/;
const TERMINATOR = /[.!?؟…:;"”»)\]’']\s*$/;
const AR_LETTER = /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/;
const LATIN_LETTER = /[A-Za-z]/;
const STRETCH_ONLY = /^\s*[t\uFFFD\uE000-\uF8FF\u0640]+\s*$/;

/** Many Arabic PDF fonts map their glyphs to the old "presentation form" code points (U+FB50–FDFF, U+FE70–FEFF) instead of the
    real letters. Phones' fonts usually lack those code points, so harakat / tanween come out as empty boxes ("أخير▯ا") and
    isolated forms break words. Map them back to the real characters (harakat, with or without a kashida, become the plain mark). */
const PRES_MARKS: Record<string, string> = {
  '\uFE70': '\u064B', '\uFE71': '\u064B', '\uFE72': '\u064C', '\uFE73': '', '\uFE74': '\u064D', '\uFE76': '\u064E', '\uFE77': '\u064E',
  '\uFE78': '\u064F', '\uFE79': '\u064F', '\uFE7A': '\u0650', '\uFE7B': '\u0650', '\uFE7C': '\u0651', '\uFE7D': '\u0651', '\uFE7E': '\u0652', '\uFE7F': '\u0652',
};
function letterWeight(c: string): number {
  if (/[اأإآدذرزوؤءةى]/.test(c)) return 0.55;
  if (/[سشصض]/.test(c)) return 1.7;
  if (/[ \u00A0]/.test(c)) return 0.4;
  if (/[ilIj.,;:'|!]/.test(c)) return 0.45;
  if (/[mwMW]/.test(c)) return 1.5;
  return 1;
}
/** Characters a phone font draws as an empty box: private-use area, the replacement char, geometric "missing glyph" squares,
    and the Arabic Extended-A "open" tanween forms (U+08F0–08F2) that many fonts lack. */
const TOFU = /[\uE000-\uF8FF\uFFFD\u25A0-\u25AF\u2610\u2395]/g;
const AR = '\u0621-\u064A\u066E-\u06D3\u06FA-\u06FF';
export function fixArabicForms(s: string): string {
  if (/[\u08F0-\u08F2]/.test(s)) s = s.replace(/\u08F0/g, '\u064B').replace(/\u08F1/g, '\u064C').replace(/\u08F2/g, '\u064D');
  if (TOFU.test(s)) {
    TOFU.lastIndex = 0;
    const onlyTofu = !s.replace(TOFU, '').trim();
    // a lone box is a stand-alone mark; a box between an Arabic letter and a final alef is the tanween (عملًا، أخيرًا، مكتبيًا)
    s = onlyTofu
      ? s.replace(TOFU, '\u064B')
      : s.replace(new RegExp(`(?<=[${AR}])${TOFU.source}+(?=\\u0627)`, 'g'), '\u064B').replace(TOFU, '');
  }
  TOFU.lastIndex = 0;
  if (!/[\uFB50-\uFDFF\uFE70-\uFEFF]/.test(s)) return s;
  return s
    .replace(/[\uFE70-\uFE7F]/g, (c) => PRES_MARKS[c] ?? '')
    .replace(/[\uFB50-\uFDFF\uFE80-\uFEFF]+/g, (m) => m.normalize('NFKC'));   // letters, lam-alef, "الله", ...
}

/** Justified Arabic text is stretched with kashida ("ـ"). Some PDF fonts map that glyph to the Latin letter "t" (or to nothing),
    so the text comes out as "بttدايات" or "متجtt ر". This removes such junk when it touches Arabic letters, and reports whether
    it sat at the start / end of the string (the stretch joins the neighbouring letters: no word space there). */
export function cleanStretch(raw: string): { s: string; before: boolean; after: boolean } {
  let before = false;
  let after = false;
  if (!AR_LETTER.test(raw)) return { s: raw, before, after };
  const s = raw.replace(/\u0640+|[t\uFFFD\uE000-\uF8FF]+/g, (m, off: number, str: string) => {
    if (m[0] !== '\u0640') {
      const prev = str[off - 1];
      const next = str[off + m.length];
      const arPrev = !!prev && AR_LETTER.test(prev);
      const arNext = !!next && AR_LETTER.test(next);
      const latPrev = !!prev && LATIN_LETTER.test(prev);
      const latNext = !!next && LATIN_LETTER.test(next);
      if (!((arPrev && !latNext) || (arNext && !latPrev))) return m;   // part of a real Latin word: keep
    }
    if (off === 0) before = true;
    if (off + m.length === str.length) after = true;
    return '';
  });
  return { s, before, after };
}

/** All text of a page's items as one string (for search), with the kashida junk removed and no false word breaks. */
export function itemsToText(items: any[]): string {
  let out = '';
  let glue = false;
  for (const it of items) {
    const raw: string = fixArabicForms(it?.str ?? '');
    if (STRETCH_ONLY.test(raw) && AR_LETTER.test(out.slice(-1))) {
      glue = true;
      continue;
    }
    const c = cleanStretch(raw);
    out += (out && !glue && !c.before ? ' ' : '') + c.s + (it?.hasEOL ? '\n' : '');
    glue = c.after;
  }
  return out.replace(/\s+/g, ' ');
}

/** Does this line open a new list entry / table-of-contents entry? ("الفصل 3: ..", "الفصل الخامس: ..", "Chapter 4", "1) ..", "• ..")
    Deliberately strict: a wrapped line of ordinary prose may start with "part of" or "الفصل بين", which must NOT split a paragraph. */
const LABEL_WORDS = /^(?:الفصل|فصل|الباب|باب|الجزء|جزء|الملحق|ملحق|chapter|chap\.|part|section|volume|vol\.|chapitre|partie|livre|tome)(?=[\s:：.\-–—]|$)/i;
const ORDINAL = /^(?:ال)?(?:أول|اول|ثاني|ثالث|رابع|خامس|سادس|سابع|ثامن|تاسع|عاشر|حادي|أخير|اخير|إضافي|اضافي|تمهيدي|ختامي)|^(?:[0-9٠-٩]+|[ivx]{1,5})(?=[\s:：.)\-–—]|$)|^(?:one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|premier|deuxième)\b/i;
function opensEntry(text: string): boolean {
  const t = text.trim();
  if (/^[•●▪◦■□▶►‣·*]\s/.test(t) || /^[–—-]\s\S/.test(t)) return true;               // bullets
  if (/^[0-9٠-٩]{1,4}\s*[.:)]\s*\S/.test(t)) return true;                              // "1) ..", "2. .."
  const m = LABEL_WORDS.exec(t);
  if (!m) return false;
  const rest = t.slice(m[0].length).replace(/^[\s:：.\-–—]+/, '');
  return /^[:：]/.test(t.slice(m[0].length).trim()) || ORDINAL.test(rest) || /^\S+(?:\s+\S+){0,3}\s*[:：]/.test(rest);
}
interface Frag { s: string; x: number; y: number; w: number; h: number; kb?: boolean; ka?: boolean }
interface Line { y: number; h: number; x0: number; x1: number; text: string; rtl: boolean }

const isRtl = (s: string) => (s.match(RTL_RE)?.length ?? 0) > (s.match(LTR_RE)?.length ?? 0);
const median = (a: number[]) => {
  if (!a.length) return 0;
  const b = [...a].sort((x, y) => x - y);
  return b[Math.floor(b.length / 2)];
};

export async function extractPage(doc: any, num: number): Promise<PageText> {
  const page = await doc.getPage(num);
  const vp = page.getViewport({ scale: 1 });
  const tc = await page.getTextContent();
  page.cleanup?.();

  const oddCount = new Map<string, number>();
  for (const it of tc.items as any[]) {
    if (typeof it.str !== 'string') continue;
    for (const ch of it.str) {
      if (/[\u0020-\u007E\u00A0-\u00FF\u0621-\u064A\u066E-\u06D3\u2000-\u206F\u0660-\u0669\u060C\u061B\u061F\s]/.test(ch)) continue;
      const k = ch.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0');
      oddCount.set(k, (oddCount.get(k) ?? 0) + 1);
    }
  }
  const odd = [...oddCount].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, n]) => `${k}×${n}`).join(' ') || undefined;

  const frags: Frag[] = [];
  for (const it of tc.items as any[]) {
    if (typeof it.str !== 'string' || !it.str.trim()) continue;
    const t = it.transform as number[];
    const h = Math.hypot(t[2], t[3]) || it.height || 10;
    frags.push({ s: fixArabicForms(it.str), x: t[4], y: t[5], w: it.width ?? 0, h });
  }
  if (!frags.length) return { paras: [], chars: 0, endsOpen: false };

  /* ---- remove kashida junk ("tt") that some fonts produce for the stretch of justified Arabic ---- */
  {
    const arabic = frags.filter((f) => AR_LETTER.test(f.s));
    const nearArabic = (f: Frag) =>
      arabic.some((a) => Math.abs(a.y - f.y) < 0.6 * Math.max(a.h, f.h) && f.x > a.x - 4 * a.h && f.x < a.x + a.w + 4 * a.h);
    for (const f of frags) {
      if (STRETCH_ONLY.test(f.s)) {
        if (nearArabic(f)) {
          f.s = '';
          f.kb = f.ka = true;
        }
        continue;
      }
      const c = cleanStretch(f.s);
      if (c.s !== f.s) {
        f.s = c.s;
        f.kb = c.before;
        f.ka = c.after;
      }
    }
  }

  /* ---- attach stand-alone diacritics to the letter they sit on ----
     Many PDFs draw harakat as separate glyphs placed above/below the letter. If they were treated as
     ordinary fragments they would be sorted by x and end up before their letter (or get a space). */
  {
    const marks = frags.filter((f) => MARK_ONLY.test(f.s.trim()));
    if (marks.length) {
      const bases = frags.filter((f) => !MARK_ONLY.test(f.s.trim()));
      for (const m of marks) {
        const cx = m.w > 0.5 ? m.x + m.w / 2 : m.x;
        let best: Frag | null = null;
        let bestD = Infinity;
        for (const b of bases) {
          if (Math.abs(b.y - m.y) > b.h * 1.6) continue;
          if (cx < b.x - b.h * 0.3 || cx > b.x + b.w + b.h * 0.3) continue;
          const d = Math.abs(b.x + b.w / 2 - cx);
          if (d < bestD) {
            bestD = d;
            best = b;
          }
        }
        if (!best) continue;
        const mark = m.s.trim();
        const len = best.s.length;
        if (len <= 2 || best.w <= 0) {
          best.s += mark;
        } else {
          const rtl = isRtl(best.s);
          const rel = Math.min(1, Math.max(0, rtl ? (best.x + best.w - cx) / best.w : (cx - best.x) / best.w));
          // insert after the letter under the mark (skipping marks already present)
          // letters have very different widths (ا ر و are narrow, س ش ص wide, spaces too): weight by estimated width
          // and ignore marks that are already attached, instead of assuming equal-width characters
          const chars = [...best.s];
          const wts = chars.map((c) => (MARK_ONLY.test(c) ? 0 : letterWeight(c)));
          const total = wts.reduce((a, b) => a + b, 0) || 1;
          // in RTL the text runs right-to-left, so `rel` already counts from the first (rightmost) character
          let acc = 0;
          let idx = chars.length - 1;
          for (let i = 0; i < chars.length; i++) {
            acc += wts[i];
            if (acc / total >= rel - 1e-9 && wts[i] > 0) { idx = i; break; }
          }
          while (idx < chars.length - 1 && MARK_ONLY.test(chars[idx + 1])) idx++;
          chars.splice(idx + 1, 0, mark);
          best.s = chars.join('');
        }
      }
      frags.splice(0, frags.length, ...bases);
      if (!frags.length) return { paras: [], chars: 0, endsOpen: false };
    }
  }

  /* ---- group fragments into lines ---- */
  frags.sort((a, b) => b.y - a.y || a.x - b.x);
  const groups: Frag[][] = [];
  for (const f of frags) {
    const g = groups.find((gr) => {
      const ref = gr[0];
      return Math.abs(ref.y - f.y) < 0.45 * Math.max(ref.h, f.h);
    });
    g ? g.push(f) : groups.push([f]);
  }
  const lines: Line[] = groups.map((gr) => {
    const joined = gr.map((f) => f.s).join('');
    const rtl = isRtl(joined);
    gr.sort((a, b) => (rtl ? b.x - a.x : a.x - b.x));
    const h = Math.max(...gr.map((f) => f.h));
    let text = '';
    gr.forEach((f, k) => {
      if (k > 0) {
        const prev = gr[k - 1];
        const gap = rtl ? prev.x - (f.x + f.w) : f.x - (prev.x + prev.w);
        // Word gaps are ~0.25em; the gap after Arabic non-joining letters (ا د ذ ر ز و) is far smaller.
        const word = gap > (rtl ? 0.24 : 0.17) * h && !prev.ka && !f.kb;   // a kashida joins its neighbours: no word space
        if (word && !text.endsWith(' ') && !f.s.startsWith(' ') && !MARK_ONLY.test(f.s[0])) text += ' ';
      }
      text += f.s;
    });
    return {
      y: gr.reduce((a, f) => a + f.y, 0) / gr.length,
      h,
      x0: Math.min(...gr.map((f) => f.x)),
      x1: Math.max(...gr.map((f) => f.x + f.w)),
      text: text.replace(/\s+/g, ' ').trim(),
      rtl,
    };
  });
  lines.sort((a, b) => b.y - a.y);

  /* ---- drop page numbers / running heads at the extreme top or bottom ---- */
  const H = vp.height;
  const kept = lines.filter((l) => {
    const edge = l.y > H * 0.93 || l.y < H * 0.07;
    return !(edge && /^[\d\s\-–—•.٠-٩]{1,8}$/.test(l.text));
  });
  if (!kept.length) return { paras: [], chars: 0, endsOpen: false };

  const body = median(kept.map((l) => l.h));
  const gaps: number[] = [];
  for (let i = 1; i < kept.length; i++) {
    const d = kept[i - 1].y - kept[i].y;
    if (d > 0 && d < body * 3) gaps.push(d);
  }
  const typical = median(gaps) || body * 1.3;
  const colLeft = median(kept.map((l) => l.x0).sort((a, b) => a - b).slice(0, Math.max(1, Math.ceil(kept.length * 0.3))));
  const colRight = median(kept.map((l) => l.x1).sort((a, b) => b - a).slice(0, Math.max(1, Math.ceil(kept.length * 0.3))));
  const colW = Math.max(1, colRight - colLeft);
  const isHead = (l: Line) => l.h > body * 1.22 && l.text.length < 140;

  /* A run of 3+ consecutive short lines (table of contents, lists, verse, addresses) is never one paragraph:
     ordinary prose does not wrap into several lines that are all far shorter than the column. */
  const widthOf = (l: Line) => l.x1 - l.x0;
  const isShortLine = (l: Line) => widthOf(l) < colW * 0.85 && l.text.length < 70;
  const inShortRun = new Array<boolean>(kept.length).fill(false);
  for (let i = 0; i < kept.length; ) {
    if (!isShortLine(kept[i])) {
      i++;
      continue;
    }
    let j = i;
    while (j + 1 < kept.length && isShortLine(kept[j + 1]) && kept[j].y - kept[j + 1].y < typical * 1.55) j++;
    if (j - i + 1 >= 3) for (let k = i; k <= j; k++) inShortRun[k] = true;
    i = j + 1;
  }

  /* ---- lines → paragraphs ---- */
  type Raw = { text: string; head: boolean };
  const raws: Raw[] = [];
  let cur: Raw | null = null;
  let prev: Line | null = null;
  let prevIdx = -1;
  for (let idx = 0; idx < kept.length; idx++) {
    const l = kept[idx];
    const head = isHead(l);
    let startNew = !cur || !prev;
    if (!startNew && prev && cur) {
      const ended = TERMINATOR.test(prev.text);
      const bigGap = prev.y - l.y > typical * 1.55;
      const short = (prev.x1 - prev.x0) < colW * 0.8;
      const indent = l.rtl ? colRight - l.x1 > body * 0.8 : l.x0 - colLeft > body * 0.8;
      const listy = inShortRun[idx] && inShortRun[prevIdx];       // both lines belong to the same list-like run
      const item = opensEntry(l.text) && !/-$/.test(prev.text); // this line opens a new entry
      startNew = head !== cur.head || bigGap || (ended && (short || indent)) || listy || item;
    }
    if (startNew) {
      cur = { text: l.text, head };
      raws.push(cur);
    } else if (cur) {
      if (cur.text.endsWith('-') && /^[a-zà-ÿ]/.test(l.text)) cur.text = cur.text.slice(0, -1) + l.text;
      else cur.text += ' ' + l.text;
    }
    prev = l;
    prevIdx = idx;
  }

  const paras: Para[] = raws
    .map((r) => {
      // a fathatan always sits on the letter before the final alef (عملًا): put a misplaced one back
      const text = r.text.normalize('NFKC').replace(/\s+/g, ' ').trim()
        .replace(/\u064B([\u0621-\u0648\u064A]{1,8})\u0627(?![\u0621-\u064A])/g, '$1\u064B\u0627');
      return { text, kind: (r.head ? 'h' : 'p') as 'h' | 'p', rtl: isRtl(text) };
    })
    .filter((p) => p.text.length > 0);

  const last = paras[paras.length - 1];
  return {
    paras,
    chars: paras.reduce((a, p) => a + p.text.length, 0),
    endsOpen: !!last && last.kind === 'p' && !TERMINATOR.test(last.text),
    odd,
  };
}
