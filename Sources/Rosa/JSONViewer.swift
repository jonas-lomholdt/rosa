import WebKit

/// Pretty-prints JSON responses. WebKit shows `application/json` (and `+json` types) as one
/// `<pre>` of raw text; this script, injected in the same isolated world as link hints, swaps in
/// an indented, syntax-coloured copy with a Raw / Pretty toggle. It formats from the original
/// text rather than re-serializing, so big numbers and key order survive. Styles go in a
/// constructable stylesheet because a `<style>` element is blocked by CSPs like `default-src 'none'`.
@MainActor
enum JSONViewer {
    static let userScript = WKUserScript(
        source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: LinkHints.contentWorld
    )

    private static let script = #"""
        (() => {
          if (window.__rosaJSON) return;
          window.__rosaJSON = true;
          if (!/^(application|text)\/([\w.-]+\+)?json$/i.test(document.contentType || '')) return;
          const body = document.body, raw = body && body.childElementCount === 1 && body.firstElementChild;
          if (!raw || raw.tagName !== 'PRE') return;
          const source = raw.textContent;
          // Anti-hijacking prefixes some APIs put before the JSON.
          const prefix = /^\s*(?:\)\]\}'|while\s*\(1\);|for\s*\(;;\);)/.exec(source);
          const text = prefix ? source.slice(prefix[0].length) : source;
          try { JSON.parse(text); } catch { return; }

          // Past this size, indent only: a span per token gets slow.
          const HIGHLIGHT_LIMIT = 3_000_000;
          const highlight = text.length <= HIGHLIGHT_LIMIT;
          const pretty = document.createElement('pre');
          pretty.className = 'rosa-json';
          let plain = '';
          const emit = (cls, value) => {
            if (!highlight || !cls) { plain += value; return; }
            if (plain) { pretty.append(plain); plain = ''; }
            const span = document.createElement('span');
            span.className = cls;
            span.textContent = value;
            pretty.append(span);
          };

          const INDENT = '  ';
          const token = /\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\],:])/y;
          const nextChar = () => { const m = /\s*/y; m.lastIndex = token.lastIndex; m.exec(text); return text[m.lastIndex]; };
          let depth = 0, m;
          token.lastIndex = 0;
          while ((m = token.exec(text))) {
            const t = m[1], c = t[0];
            if (c === '{' || c === '[') {
              const close = c === '{' ? '}' : ']';
              if (nextChar() === close) { token.exec(text); emit('', c + close); continue; }
              depth++;
              emit('', c + '\n' + INDENT.repeat(depth));
            } else if (c === '}' || c === ']') {
              depth--;
              emit('', '\n' + INDENT.repeat(depth) + c);
            } else if (c === ',') {
              emit('', ',\n' + INDENT.repeat(depth));
            } else if (c === ':') {
              emit('', ': ');
            } else if (c === '"') {
              emit(nextChar() === ':' ? 'k' : 's', t);
            } else if (c === 't' || c === 'f') {
              emit('b', t);
            } else if (c === 'n') {
              emit('z', t);
            } else {
              emit('n', t);
            }
          }
          if (plain) pretty.append(plain);

          const sheet = new CSSStyleSheet();
          sheet.replaceSync(`
            :root { color-scheme: light dark; --k: #0451a5; --s: #a31515; --n: #098658; --b: #0000ff; --z: #0000ff;
                    --bar: rgba(0,0,0,.05); --bar-on: rgba(0,0,0,.12); }
            @media (prefers-color-scheme: dark) {
              :root { --k: #9cdcfe; --s: #ce9178; --n: #b5cea8; --b: #569cd6; --z: #569cd6;
                      --bar: rgba(255,255,255,.08); --bar-on: rgba(255,255,255,.2); }
            }
            body { margin: 0; }
            body > pre { margin: 0; padding: 12px 16px; font: 12px/1.5 ui-monospace, Menlo, monospace;
                         white-space: pre-wrap; overflow-wrap: anywhere; }
            [hidden] { display: none !important; }
            .rosa-json .k { color: var(--k); } .rosa-json .s { color: var(--s); }
            .rosa-json .n { color: var(--n); } .rosa-json .b { color: var(--b); } .rosa-json .z { color: var(--z); }
            .rosa-json-bar { position: fixed; top: 8px; right: 12px; display: flex; gap: 2px; padding: 2px;
                             border-radius: 7px; background: var(--bar); backdrop-filter: blur(12px);
                             font: 11px -apple-system, sans-serif; }
            .rosa-json-bar button { all: unset; padding: 3px 9px; border-radius: 5px; cursor: default; }
            .rosa-json-bar button[aria-pressed="true"] { background: var(--bar-on); }
          `);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];

          const bar = document.createElement('div');
          bar.className = 'rosa-json-bar';
          const buttons = ['Raw', 'Pretty'].map(label => {
            const button = document.createElement('button');
            button.textContent = label;
            button.addEventListener('click', () => show(label === 'Pretty'));
            bar.append(button);
            return button;
          });
          function show(isPretty) {
            pretty.hidden = !isPretty;
            raw.hidden = isPretty;
            buttons[0].setAttribute('aria-pressed', String(!isPretty));
            buttons[1].setAttribute('aria-pressed', String(isPretty));
          }
          body.append(pretty, bar);
          show(true);
        })();
        """#
}
