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

/** Letters that connect to the NEXT letter (everything except ا د ذ ر ز و and their hamza / ة / ى variants). */
const FWD_JOIN = '\u0628\u062A\u062B\u062C\u062D\u062E\u0633\u0634\u0635\u0636\u0637\u0638\u0639\u063A\u0641\u0642\u0643\u0644\u0645\u0646\u0647\u064A\u0626';
/** A fragment that is exactly one Arabic letter (plus marks), other than و (which is a real one-letter word, "and"). */
const STRAY_RE = /^[\u0621-\u0647\u0649\u064A][\u064B-\u0652]*$/;
/** kasra+shadda in either order: in the "dotted nun" fonts this pair is the ن glyph's dot, never real vocalisation. */
const NUN_JUNK = '(?:\u0650\u0651|\u0651\u0650)';
const NUN_COMPOSITE = /^ن[A-Z]?[\u064B-\u0652\u0640\u0080-\u009F]+$/;

/** Does this page use the font whose ن is a zero-width glyph made of marks ("نِّ", "نَ", "نNِّ")? */
export function hasDottedNun(items: any[]): boolean {
  let n = 0;
  for (const it of items) {
    if (typeof it?.str !== 'string') continue;
    const t = it.str.trim();
    if (t.length > 1 && t.length < 8 && NUN_COMPOSITE.test(t) && /[\u064B-\u0652]/.test(t) && (it.width ?? 0) < 1) {
      return true;
    }
  }
  return false;
}

/** Text-level safety net for the dotted-nun font: removes the junk marks that survived (or were attached to the neighbouring
    letter instead of the ن) and the false word space in front of the ن ("يمك نِّني" → "يمكنني", "أ نَك" → "أنك"). */
export function cleanNunJunk(text: string): string {
  return text
    .replace(new RegExp(`([${FWD_JOIN}]) ?ن(?=[\u064E-\u0651])[\u064B-\u0652]*`, 'g'), '$1ن')      // letter + (space) + ن + marks
    .replace(new RegExp(`^ن(?=[\u064E-\u0651])[\u064B-\u0652]*`, 'g'), 'ن')
    .replace(new RegExp(`(?<=\\s)ن(?=[\u064E-\u0651])[\u064B-\u0652]*`, 'g'), 'ن')
    .replace(new RegExp(NUN_JUNK, 'g'), '');                                                       // marks glued to another letter
}

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
  // This kind of font encodes some harakat glyphs as single capital Latin letters (تTكرSر، المص نNِّف، أTنتج). A lone capital that
  // touches Arabic is such a glyph, not text: drop it (the original vowel mark is lost, which is harmless for reading).
  if (/[A-Z]/.test(s) && /[\u0600-\u06FF]/.test(s)) {
    const isAr = (c?: string) => !!c && /[\u0600-\u06FF\u0640]/.test(c);
    s = s.replace(/(?<![A-Za-z0-9])[A-Z](?![A-Za-z0-9])/g, (m, off: number, all: string) => (isAr(all[off - 1]) || isAr(all[off + 1]) ? '' : m));
  }
  // C1 control characters (U+0080–009F) are how some justified-Arabic fonts encode their stretch glyphs: treat as kashida
  if (/[\u0080-\u009F]/.test(s)) s = s.replace(/[\u0080-\u009F]+/g, '\u0640');
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
  const dotted = hasDottedNun(items);
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
  out = out.replace(/\s+/g, ' ');
  return dotted ? cleanNunJunk(out) : out;
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
interface Frag { s: string; x: number; y: number; w: number; h: number; kb?: boolean; ka?: boolean; nun?: boolean }
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
  const dotted = hasDottedNun(tc.items as any[]);

  const oddCount = new Map<string, number>();
  for (const it of tc.items as any[]) {
    if (typeof it.str !== 'string') continue;
    for (const ch of it.str) {
      if (/[\u0020-\u007E\u00A0-\u00FF\u0621-\u064A\u066E-\u06D3\u2000-\u206F\u0660-\u0669\u060C\u061B\u061F\s]/.test(ch)) continue;
      const k = ch.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0');
      oddCount.set(k, (oddCount.get(k) ?? 0) + 1);
    }
  }
  const oddList = [...oddCount].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, n]) => `${k}×${n}`).join(' ') || 'none';
  // raw code points of the first few fragments around the words that show boxes (عم / أخير / مكتب)
  const probe = (tc.items as any[]).filter((it) => typeof it.str === 'string' && /عم|أخير|مكتب|كنت|هند/.test(it.str)).slice(0, 4)
    .map((it) => [...it.str].map((c: string) => c.codePointAt(0)!.toString(16).toUpperCase()).join('.')).join(' | ');
  const markProbe = (tc.items as any[]).filter((it) => typeof it.str === 'string' && it.str.trim() && MARK_ONLY.test(it.str.trim())).slice(0, 5)
    .map((it) => `${it.str.trim().codePointAt(0)!.toString(16).toUpperCase()}:w${(it.width ?? 0).toFixed(1)}/h${(Math.hypot(it.transform[2], it.transform[3]) || 0).toFixed(1)}`).join(' ');
  const nunProbe = (tc.items as any[]).filter((it) => typeof it.str === 'string' && /ن[\u064E\u0650\u0651]|[\u064E\u0650\u0651]ن/.test(it.str)).slice(0, 4)
    .map((it) => `${[...it.str].map((c: string) => c.codePointAt(0)!.toString(16).toUpperCase()).join('.')}:w${(it.width ?? 0).toFixed(1)}`).join(' ; ');
  const odd = `${oddList}${nunProbe ? ' @@ ' + nunProbe : ''}${markProbe ? ' ## ' + markProbe : ''}${probe ? ' || ' + probe : ''}`;

  const frags: Frag[] = [];
  for (const it of tc.items as any[]) {
    if (typeof it.str !== 'string' || !it.str.trim()) continue;
    const t = it.transform as number[];
    const h = Math.hypot(t[2], t[3]) || it.height || 10;
    frags.push({ s: fixArabicForms(it.str), x: t[4], y: t[5], w: it.width ?? 0, h });
  }
  if (!frags.length) return { paras: [], chars: 0, endsOpen: false };

  // Some PDFs encode justification stretch glyphs with the code points of harakat. Real marks are zero- or near-zero-width;
  // a stand-alone "mark" that advances the pen is a stretch glyph, so it becomes a kashida for the cleanup below.
  for (const f of frags) if (MARK_ONLY.test(f.s.trim()) && f.w > f.h * 0.12) f.s = '\u0640';

  // In this kind of PDF the dot of ن is drawn by extra glyphs whose code points are a shadda / kasra / fatha, and the fragment
  // has zero width ("ن" + ّ + ِ, w=0). It is a plain ن (optionally followed by ا): drop the marks and give it the width of a ن so the
  // gap to its neighbours is measured correctly (a zero width made a false word space before it).
  for (const f of frags) {
    const m = f.s.replace(/\u0640/g, '').trim().match(/^ن[\u064E-\u0651]{1,4}(ا?)$/);
    if (m) { f.s = 'ن' + m[1]; f.nun = true; f.w = Math.max(f.w, f.h * (m[1] ? 0.8 : 0.45)); }
  }

  // a lone "V" / "N" between Arabic words is a glyph the font maps to a Latin letter, not text: drop it (keeps the word space)
  {
    const ar = frags.filter((f) => AR_LETTER.test(f.s));
    for (const f of frags) {
      if (/^\s*[A-Z]\s*$/.test(f.s) && f.w < f.h * 1.2 && ar.some((a) => Math.abs(a.y - f.y) < 0.6 * Math.max(a.h, f.h) && Math.abs(a.x - f.x) < 4 * a.h + a.w)) f.s = ' ';
    }
  }

  /* ---- remove kashida junk ("tt") that some fonts produce for the stretch of justified Arabic ---- */
  // Stand-alone stretch glyphs are zero-width and often share their x with a neighbouring fragment, so sorting could put them on
  // the wrong side of it. Remember where they are and decide the word joins from geometry instead of from the sort order.
  const stretches: Array<{ x: number; y: number }> = [];
  {
    const arabic = frags.filter((f) => AR_LETTER.test(f.s));
    const nearArabic = (f: Frag) =>
      arabic.some((a) => Math.abs(a.y - f.y) < 0.6 * Math.max(a.h, f.h) && f.x > a.x - 4 * a.h && f.x < a.x + a.w + 4 * a.h);
    for (const f of frags) {
      if (STRETCH_ONLY.test(f.s)) {
        if (nearArabic(f)) {
          stretches.push({ x: f.x, y: f.y });
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

  for (let i = frags.length - 1; i >= 0; i--) if (!frags[i].s) frags.splice(i, 1);
  if (!frags.length) return { paras: [], chars: 0, endsOpen: false };

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
    // 1) word break or not, for each boundary between two fragments
    const word: boolean[] = [false];
    const gaps: number[] = [0];
    for (let k = 1; k < gr.length; k++) {
      const prev = gr[k - 1], f = gr[k];
      const gap = rtl ? prev.x - (f.x + f.w) : f.x - (prev.x + prev.w);
      let lo = rtl ? f.x + f.w : prev.x + prev.w;
      let hi = rtl ? prev.x : f.x;
      if (lo > hi) [lo, hi] = [hi, lo];
      const tol = 0.2 * h;
      const stretched = stretches.some((st) => Math.abs(st.y - f.y) < 0.6 * h && st.x >= lo - tol && st.x <= hi + tol);
      gaps.push(gap);
      // Word gaps are ~0.25em; the gap after Arabic non-joining letters (ا د ذ ر ز و) is far smaller.
      // the composite ن sits inside its word: after a letter that connects forward there is no word space before it
      const nunJoin = !!f.nun && gap < 1.2 * h && FWD_JOIN.includes(prev.s.trim().slice(-1));
      word.push(gap > (rtl ? 0.24 : 0.17) * h && !prev.ka && !f.kb && !stretched && !nunJoin);   // a kashida joins its neighbours: no word space
    }
    // 2) a single Arabic letter (not و) is never a word: it belongs to the neighbour it is closest to (justified lines widen the
    //    gaps inside words: "المرخ ص", "كر ر", "ت غ ير")
    const arEnd = (t: string) => AR_LETTER.test(t.trim().slice(-1));
    const arStart = (t: string) => AR_LETTER.test(t.trim().charAt(0));
    for (let k = 0; k < gr.length; k++) {
      const t = gr[k].s.trim();
      if (!STRAY_RE.test(t) || t[0] === '\u0648') continue;
      const before = k > 0 && arEnd(gr[k - 1].s) ? gaps[k] : Infinity;
      const after = k + 1 < gr.length && arStart(gr[k + 1].s) ? gaps[k + 1] : Infinity;
      const near = Math.min(before, after);
      if (!(near < 0.8 * h)) continue;
      const far = Math.max(before, after);
      if (before <= after) word[k] = false; else word[k + 1] = false;
      if (far < 0.8 * h && far <= near * 1.6 + 0.5) { word[k] = false; if (k + 1 < gr.length) word[k + 1] = false; }
    }
    let text = '';
    gr.forEach((f, k) => {
      if (k > 0 && word[k] && !text.endsWith(' ') && !f.s.startsWith(' ') && !MARK_ONLY.test(f.s[0])) text += ' ';
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
      const text = (dotted ? cleanNunJunk(r.text.normalize('NFKC')) : r.text.normalize('NFKC')).replace(/\s+/g, ' ').trim()
        // "غيرً": the stretch glyph after ير is read as a tanween
        .replace(/(?<=\u064A\u0631)\u064B(?![\u0621-\u064A])/g, '')
        .replace(/\u064B([\u0621-\u0648\u064A]{1,8})\u0627(?![\u0621-\u064A])/g, '$1\u064B\u0627')
        // an Arabic word glued to a Latin one (الدالةprint()، عبارةif): the PDF's gap between them is lost
        .replace(/([\u0621-\u064A])(?=[A-Za-z])/g, '$1 ')
        .replace(/([A-Za-z0-9)\]])(?=[\u0621-\u064A])/g, '$1 ');
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


/** Scans every page of a PDF and returns a plain-text report of everything that looks wrong in the extracted text
    (unusual code points with real examples, and suspicious spots in the final reflowed text), to be copied to the developer. */
export async function scanPdfIssues(
  doc: any,
  onProgress: (done: number, total: number) => void,
  cancel: { cancelled: boolean },
): Promise<string> {
  const total: number = doc.numPages;
  const hex = (str: string) => [...str].map((c) => c.codePointAt(0)!.toString(16).toUpperCase()).join('.');
  const global = new Map<string, { n: number; pages: Set<number>; samples: string[] }>();
  const pageLines: string[] = [];
  const suspicious: string[] = [];
  const SUSPECT: Array<[string, RegExp]> = [
    ['Latin letter inside Arabic word', /[\u0621-\u064A][A-Za-z]|[A-Za-z][\u0621-\u064A]/],
    ['box / replacement / private-use char', /[\uE000-\uF8FF\uFFFD\u25A0-\u25AF\u0080-\u009F]/],
    ['mark after space or punctuation', /[\s.,،؛:!؟?(][\u064B-\u0652]/],
    ['two different marks in a row', /[\u064B-\u0650][\u064B-\u0652]/],
    ['single Arabic letter between spaces', /(?:^|\s)[\u0621-\u0640\u0642-\u0647\u0649\u064A](?=\s|$)/],
    ['presentation-form code point left', /[\uFB50-\uFDFF\uFE70-\uFEFF]/],
  ];
  const suspCount = new Map<string, number>();
  for (let n = 1; n <= total; n++) {
    if (cancel.cancelled) break;
    onProgress(n - 1, total);
    try {
      const page = await doc.getPage(n);
      const tc = await page.getTextContent();
      page.cleanup?.();
      const pageOdd = new Map<string, number>();
      for (const it of tc.items as any[]) {
        if (typeof it.str !== 'string') continue;
        for (const ch of it.str) {
          if (/[\u0020-\u007E\u00A0-\u00FF\u0621-\u064A\u066E-\u06D3\u2000-\u206F\u0660-\u0669\u060C\u061B\u061F\s]/.test(ch)) continue;
          const k = ch.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0');
          pageOdd.set(k, (pageOdd.get(k) ?? 0) + 1);
          let g = global.get(k);
          if (!g) global.set(k, (g = { n: 0, pages: new Set(), samples: [] }));
          g.n++;
          g.pages.add(n);
          if (g.samples.length < 4) {
            g.samples.push(`p${n} "${it.str.length > 14 ? it.str.slice(0, 14) + '…' : it.str}" = ${hex(it.str.slice(0, 14))} w=${(it.width ?? 0).toFixed(1)} h=${(Math.hypot(it.transform[2], it.transform[3]) || 0).toFixed(1)}`);
          }
        }
      }
      if (pageOdd.size) pageLines.push(`p${n}: ${[...pageOdd].map(([k, c]) => `${k}x${c}`).join(' ')}`);
      const res = await extractPage(doc, n);
      for (const para of res.paras) {
        for (const [label, re] of SUSPECT) {
          const m = re.exec(para.text);
          if (!m) continue;
          suspCount.set(label, (suspCount.get(label) ?? 0) + 1);
          if (suspicious.length < 400) {
            const a = Math.max(0, m.index - 22);
            suspicious.push(`p${n} [${label}] …${para.text.slice(a, m.index + 28)}…  (${hex(para.text.slice(m.index, m.index + 3))})`);
          }
          break;
        }
      }
    } catch (e) {
      pageLines.push(`p${n}: ERROR ${(e as Error)?.message ?? e}`);
    }
  }
  const out: string[] = [];
  out.push(`MARGINS TEXT SCAN  pages=${total}${cancel.cancelled ? '  (stopped early)' : ''}`);
  out.push('');
  out.push('== UNUSUAL CODE POINTS (whole book) ==');
  if (!global.size) out.push('none');
  for (const [k, g] of [...global].sort((a, b) => b[1].n - a[1].n).slice(0, 60)) {
    out.push(`${k}  count=${g.n}  pages=${g.pages.size}  e.g.`);
    for (const sm of g.samples) out.push(`    ${sm}`);
  }
  out.push('');
  out.push('== SUSPICIOUS SPOTS IN THE FINAL TEXT (counts) ==');
  if (!suspCount.size) out.push('none');
  for (const [k, c] of suspCount) out.push(`${k}: ${c}`);
  out.push('');
  out.push('== SUSPICIOUS SPOTS (first 400) ==');
  out.push(...(suspicious.length ? suspicious : ['none']));
  out.push('');
  out.push('== PER PAGE UNUSUAL CODE POINTS (first 300 pages with any) ==');
  out.push(...(pageLines.slice(0, 300).length ? pageLines.slice(0, 300) : ['none']));
  return out.join('\n');
}
