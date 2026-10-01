import AppKit
import WebKit

/// Keyboard navigation injected into pages, in an isolated content world so pages can
/// neither see nor tamper with it:
/// - Link hints (qutebrowser / Vimium style): `f` labels every clickable element on screen,
///   typing a label clicks it; `F` opens the link in the background (tab or pane).
/// - Vim-style scrolling: `j`/`k` scroll, `h`/`l` scroll sideways, `gg`/`G` jump to top/bottom.
/// Both are ignored while typing in a field and can be turned off in Settings → Keyboard.
@MainActor
enum LinkHints {
    static let messageName = "browserLinkHints"
    static let contentWorld = WKContentWorld.defaultClient

    /// (Re)installs the hint script with the current settings. Scripts only apply to
    /// future page loads; `configure(_:)` updates the page that is already loaded.
    static func install(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let source = script.replacingOccurrences(of: "__INITIAL_CONFIG__", with: configJSON)
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld
        ))
        // Popups share their opener's controller; a handler name may only be added once.
        if !controllersWithHandler.contains(controller) {
            controller.add(LinkHintsRouter.shared, contentWorld: contentWorld, name: messageName)
            controllersWithHandler.add(controller)
        }
    }

    static func configure(_ webView: WKWebView) {
        webView.evaluateJavaScript(
            "window.__browserHints && window.__browserHints.configure(\(configJSON))",
            in: nil, in: contentWorld
        )
    }

    static func start(in webView: WKWebView, background: Bool = false) {
        webView.evaluateJavaScript(
            "window.__browserHints && window.__browserHints.start(\(background))",
            in: nil, in: contentWorld
        )
    }

    private static let controllersWithHandler = NSHashTable<WKUserContentController>.weakObjects()

    private static var configJSON: String {
        #"{"enabled":\#(Settings.linkHintsEnabled),"color":"\#(Settings.linkHintColor)","vim":\#(Settings.vimKeysEnabled)}"#
    }

    private static let script = #"""
        (() => {
          if (window.__browserHints) return;
          const config = { enabled: true, color: '#FFD60A', vim: true };
          const SCROLL_STEP = 60;
          let pendingG = 0;
          const ALPHABET = 'sadfjklewcmpgh';
          const CLICKABLE = 'a[href], area[href], button, input:not([type="hidden"]), select, textarea, summary, ' +
            '[role="button"], [role="link"], [role="tab"], [role="checkbox"], [role="menuitem"], [role="option"], ' +
            '[onclick], [contenteditable=""], [contenteditable="true"], [tabindex]:not([tabindex="-1"])';
          let state = null;
          const swallowed = new Set();

          function configure(next) {
            if (typeof next.enabled === 'boolean') config.enabled = next.enabled;
            if (/^#[0-9a-fA-F]{6}$/.test(next.color || '')) config.color = next.color;
            if (typeof next.vim === 'boolean') config.vim = next.vim;
            if (!config.enabled) stop();
          }

          function isEditable(el) {
            if (!el) return false;
            if (el.isContentEditable) return true;
            if (el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') return true;
            if (el.tagName !== 'INPUT') return false;
            const type = (el.type || '').toLowerCase();
            return !['button', 'submit', 'reset', 'checkbox', 'radio', 'image', 'file', 'range', 'color'].includes(type);
          }

          // Visible, unobscured clickable elements in the viewport (outermost one wins when nested).
          function targets() {
            const vw = innerWidth, vh = innerHeight, chosen = new Set(), out = [];
            for (const el of document.querySelectorAll(CLICKABLE)) {
              if (el.disabled) continue;
              const rect = Array.from(el.getClientRects()).find(r =>
                r.width > 1 && r.height > 1 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw);
              if (!rect) continue;
              const style = getComputedStyle(el);
              if (style.visibility !== 'visible' || parseFloat(style.opacity) === 0) continue;
              const x = Math.min(Math.max(rect.left + rect.width / 2, 0), vw - 1);
              const y = Math.min(Math.max(rect.top + rect.height / 2, 0), vh - 1);
              const hit = document.elementFromPoint(x, y);
              if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) continue;
              let parent = el.parentElement, nested = false;
              while (parent) { if (chosen.has(parent)) { nested = true; break; } parent = parent.parentElement; }
              if (nested) continue;
              chosen.add(el);
              out.push({ el, rect });
            }
            return out;
          }

          // Prefix-free labels (Vimium's scheme): no label starts another, so a match is final.
          function labels(count) {
            let hints = [''], offset = 0;
            while (hints.length - offset < count || hints.length === 1) {
              const hint = hints[offset++];
              for (const ch of ALPHABET) hints.push(ch + hint);
            }
            return hints.slice(offset, offset + count).sort().map(h => h.split('').reverse().join(''));
          }

          function start(background) {
            stop();
            if (!config.enabled) return;
            const found = targets();
            if (!found.length) return;
            const names = labels(found.length);
            const host = document.createElement('div');
            host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
            const root = host.attachShadow({ mode: 'closed' });
            const style = document.createElement('style');
            style.textContent =
              '.hint{position:fixed;font:700 11px/1.25 -apple-system,system-ui,sans-serif;color:#1d1d1f;' +
              'background:' + config.color + ';padding:1px 4px;border-radius:4px;border:1px solid rgba(0,0,0,.35);' +
              'box-shadow:0 1px 3px rgba(0,0,0,.3);text-transform:uppercase;letter-spacing:.5px;white-space:nowrap}' +
              '.typed{opacity:.35}';
            root.appendChild(style);
            const hints = found.map(({ el, rect }, i) => {
              const div = document.createElement('div');
              div.className = 'hint';
              div.style.left = Math.max(0, rect.left) + 'px';
              div.style.top = Math.max(0, rect.top) + 'px';
              root.appendChild(div);
              return { el, label: names[i], div };
            });
            document.documentElement.appendChild(host);
            state = { hints, typed: '', background, host };
            render();
          }

          function stop() {
            if (!state) return;
            state.host.remove();
            state = null;
          }

          function render() {
            let matches = 0, last = null;
            for (const hint of state.hints) {
              const match = hint.label.startsWith(state.typed);
              hint.div.style.display = match ? '' : 'none';
              if (!match) continue;
              matches++;
              last = hint;
              hint.div.replaceChildren();
              const typed = document.createElement('span');
              typed.className = 'typed';
              typed.textContent = state.typed;
              hint.div.append(typed, hint.label.slice(state.typed.length));
            }
            return { matches, last };
          }

          function activate(hint) {
            const background = state.background;
            stop();
            const el = hint.el;
            if (isEditable(el)) { el.focus(); return; }
            const href = typeof el.href === 'string' ? el.href : null;
            if (background && href) {
              window.webkit.messageHandlers.browserLinkHints.postMessage({ url: href });
              return;
            }
            el.focus({ preventScroll: true });
            el.click();
          }

          // The element that actually scrolls: many sites scroll an inner panel, not the page.
          function scrollTarget(horizontal) {
            let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
            while (el && el !== document.body && el !== document.documentElement) {
              const style = getComputedStyle(el);
              const overflow = horizontal ? style.overflowX : style.overflowY;
              const scrollable = horizontal ? el.scrollWidth > el.clientWidth + 1 : el.scrollHeight > el.clientHeight + 1;
              if (/(auto|scroll|overlay)/.test(overflow) && scrollable) return el;
              el = el.parentElement;
            }
            return document.scrollingElement || document.documentElement;
          }

          // Returns true if the key was a vim command.
          function vimKey(event) {
            const target = scrollTarget(event.key === 'h' || event.key === 'l');
            const behavior = event.repeat ? 'auto' : 'smooth';
            switch (event.key) {
              case 'h': target.scrollBy({ left: -SCROLL_STEP, behavior }); return true;
              case 'l': target.scrollBy({ left: SCROLL_STEP, behavior }); return true;
              case 'j': target.scrollBy({ top: SCROLL_STEP, behavior: event.repeat ? 'auto' : 'smooth' }); return true;
              case 'k': target.scrollBy({ top: -SCROLL_STEP, behavior: event.repeat ? 'auto' : 'smooth' }); return true;
              case 'G': target.scrollTo({ top: target.scrollHeight, behavior: 'smooth' }); return true;
              case 'g':
                if (event.repeat) return true;
                if (Date.now() - pendingG < 800) {
                  pendingG = 0;
                  target.scrollTo({ top: 0, behavior: 'smooth' });
                } else {
                  pendingG = Date.now();
                }
                return true;
            }
            return false;
          }

          function swallow(event) {
            event.preventDefault();
            event.stopImmediatePropagation();
            swallowed.add(event.code);
          }

          window.addEventListener('keydown', event => {
            if (state) {
              swallow(event);
              if (event.key === 'Escape') return stop();
              if (event.key === 'Backspace') { state.typed = state.typed.slice(0, -1); render(); return; }
              const ch = event.key.length === 1 ? event.key.toLowerCase() : '';
              if (!ch || !ALPHABET.includes(ch)) return;
              state.typed += ch;
              const { matches, last } = render();
              if (matches === 0) { state.typed = state.typed.slice(0, -1); render(); }
              else if (matches === 1 && last.label === state.typed) activate(last);
              return;
            }
            if (event.metaKey || event.ctrlKey || event.altKey) return;
            if (isEditable(document.activeElement) || isEditable(event.target)) return;
            if (config.vim && vimKey(event)) { swallow(event); return; }
            if (!config.enabled || event.repeat) return;
            if (event.key !== 'f' && event.key !== 'F') return;
            swallow(event);
            start(event.shiftKey);
          }, true);

          for (const type of ['keypress', 'keyup']) {
            window.addEventListener(type, event => {
              if (!swallowed.has(event.code)) return;
              event.preventDefault();
              event.stopImmediatePropagation();
              if (type === 'keyup') swallowed.delete(event.code);
            }, true);
          }
          for (const type of ['scroll', 'resize', 'blur', 'mousedown']) {
            window.addEventListener(type, () => stop(), true);
          }

          configure(__INITIAL_CONFIG__);
          window.__browserHints = {
            start, stop, configure,
            debugLabels: () => state ? state.hints.map(h => h.label + ':' + (h.el.id || h.el.tagName)) : [],
          };
        })();
        """#
}

/// Receives "open in background" requests from hint scripts and routes them to the pane
/// whose web view sent them. One shared handler, since popups share a content controller.
@MainActor
final class LinkHintsRouter: NSObject, WKScriptMessageHandler {
    static let shared = LinkHintsRouter()

    private let panes = NSMapTable<WKWebView, PaneView>.weakToWeakObjects()

    func register(_ pane: PaneView) {
        panes.setObject(pane, forKey: pane.webView)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let pane = panes.object(forKey: webView),
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        pane.openLinkInBackground(url)
    }
}

extension NSColor {
    /// "#RRGGBB" → colour (nil if malformed).
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFD60A" }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
