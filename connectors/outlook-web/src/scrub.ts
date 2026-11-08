// Makes a shareable sample of the Outlook page: same elements and class names, with every name, address, id and piece
// of message text replaced by placeholders. Bare times and dates are kept so the sample still parses. Works on a copy;
// the live page is never changed.

const EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;
const HAS_EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
const TIME_TOKEN =
  /^(\d{1,2}:\d{2}|\d{1,2}[/.-]\d{1,2}[/.-](\d{2}|\d{4})|[AP]M|(mon|tue|wed|thu|fri|sat|sun)(day|sday|nesday|rsday|urday)?\.?,?|today|yesterday)$/i;
// Status words Outlook puts in row labels; kept in attributes so unread detection still works on the sample.
const LABEL_WORDS = new Set(["unread", "read", "flagged", "pinned", "has", "attachments", "attachment", "replied", "forwarded", "important", "draft", "message", "list"]);
// Attributes that describe structure, never content.
const KEEP_ATTRS = new Set([
  "class", "role", "style", "type", "tabindex", "dir", "lang", "width", "height", "draggable", "charset", "rel",
  "aria-hidden", "aria-selected", "aria-expanded", "aria-checked", "aria-level", "aria-posinset", "aria-setsize",
  "aria-multiselectable", "aria-live", "aria-haspopup", "aria-orientation", "aria-readonly", "aria-disabled",
  "aria-current", "aria-busy", "aria-atomic",
]);
// Icon geometry: never personal, and Chrome logs an error for each SVG shape attribute set to a placeholder.
const SVG_GEOMETRY = new Set([
  "d", "viewBox", "points", "transform", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy",
  "offset", "width", "height", "fill", "stroke", "stroke-width", "fill-rule", "clip-rule", "opacity", "stop-color",
  "stop-opacity", "gradientUnits", "gradientTransform", "preserveAspectRatio", "xmlns", "focusable",
]);
const SVG_NS = "http://www.w3.org/2000/svg";
const ID_ATTRS = new Set(["id", "for", "aria-labelledby", "aria-describedby", "aria-controls", "aria-owns"]);
const URL_ATTRS = new Set(["href", "src", "action", "srcset", "poster", "data-src"]);

class Placeholders {
  private words = new Map<string, string>();
  private emails = new Map<string, string>();
  word(w: string): string {
    let p = this.words.get(w);
    if (!p) this.words.set(w, (p = `w${this.words.size + 1}`));
    return p;
  }
  email(e: string): string {
    const k = e.toLowerCase();
    let p = this.emails.get(k);
    if (!p) this.emails.set(k, (p = `person${this.emails.size + 1}@example.invalid`));
    return p;
  }
}

/** A structural id such as "mectrl_main_trigger" or "app" (not an item id, name or address). */
function structuralId(token: string, attr: string): boolean {
  if (token.length > 48 || /\d{4}/.test(token) || token.includes("@")) return false;
  if (/^[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+$/.test(token)) return true;
  return attr === "id" && /^[a-z]{1,12}$/.test(token);
}

function scrubText(value: string, ph: Placeholders, keep: (token: string) => boolean): string {
  return value
    .split(/(\s+)/)
    .map((tok) => {
      if (!tok || /^\s+$/.test(tok)) return tok;
      if (HAS_EMAIL.test(tok)) return tok.replace(EMAIL, (e) => ph.email(e));
      if (TIME_TOKEN.test(tok) || keep(tok)) return tok;
      return ph.word(tok);
    })
    .join("");
}

function scrubUrl(value: string, ph: Placeholders): string {
  try {
    const u = new URL(value);
    return `${u.protocol}//${u.host}/${ph.word(u.pathname + u.search + u.hash)}`;
  } catch {
    return value ? ph.word(value) : value;
  }
}

function scrubAttr(el: Element, name: string, value: string, ph: Placeholders): string {
  if (URL_ATTRS.has(name)) return scrubUrl(value, ph);
  const id = ID_ATTRS.has(name) || name.startsWith("data-");
  return scrubText(value, ph, (tok) => LABEL_WORDS.has(tok.toLowerCase()) || (id && structuralId(tok, name)));
}

export function scrubSample(doc: Document): string {
  const root = doc.documentElement.cloneNode(true) as Element;
  const ph = new Placeholders();
  // 1 = SHOW_ELEMENT, 4 = SHOW_TEXT, 128 = SHOW_COMMENT
  const walker = doc.createTreeWalker(root, 1 | 4 | 128);
  for (let node: Node | null = root; node; node = walker.nextNode()) {
    if (node.nodeType === 1) {
      const el = node as Element;
      for (const attr of Array.from(el.attributes)) {
        if (KEEP_ATTRS.has(attr.name)) continue;
        if (el.namespaceURI === SVG_NS && SVG_GEOMETRY.has(attr.name)) continue;
        el.setAttribute(attr.name, scrubAttr(el, attr.name, attr.value, ph));
      }
    } else if (node.nodeType === 3) {
      node.nodeValue = scrubText(node.nodeValue ?? "", ph, () => false);
    } else if (node.nodeType === 8) {
      node.nodeValue = "";
    }
  }
  return `<!doctype html>\n${root.outerHTML}\n`;
}
