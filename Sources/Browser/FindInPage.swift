import WebKit

/// Find-in-page engine injected into pages. Uses the CSS Custom Highlight API, so matches are
/// painted in a configurable colour (all matches tinted, the current one solid) without
/// touching the page's DOM, and the current match "pops" like Safari's find indicator.
/// Case-insensitive; matches within a single text node.
@MainActor
enum FindInPage {
    static let userScript = WKUserScript(
        source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: LinkHints.contentWorld
    )

    /// Starts a new search; returns (1-based index of the current match, match count).
    static func start(_ query: String, in webView: WKWebView) async -> (index: Int, count: Int) {
        await call("return window.__browserFind ? window.__browserFind.start(query, color) : null",
                   ["query": query, "color": Settings.findHighlightColor], in: webView)
    }

    static func step(_ delta: Int, in webView: WKWebView) async -> (index: Int, count: Int) {
        await call("return window.__browserFind ? window.__browserFind.step(delta) : null", ["delta": delta], in: webView)
    }

    static func clear(in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            "window.__browserFind && window.__browserFind.clear()", arguments: [:], in: nil, contentWorld: LinkHints.contentWorld
        )
    }

    private static func call(_ body: String, _ arguments: [String: Any], in webView: WKWebView) async -> (index: Int, count: Int) {
        let result = (try? await webView.callAsyncJavaScript(
            body, arguments: arguments, in: nil, contentWorld: LinkHints.contentWorld
        )) as? [String: Any]
        return (result?["index"] as? Int ?? 0, result?["count"] as? Int ?? 0)
    }

    private static let script = #"""
        (() => {
          if (window.__browserFind) return;
          let ranges = [], index = -1, style = null, popColor = '#32D74B', popHost = null;

          function applyColor(color) {
            if (!/^#[0-9a-fA-F]{6}$/.test(color || '')) color = '#32D74B';
            popColor = color;
            if (!style) {
              style = document.createElement('style');
              (document.head || document.documentElement).appendChild(style);
            }
            style.textContent =
              '::highlight(browser-find){background-color:' + color + '66;color:inherit}' +
              '::highlight(browser-find-current){background-color:' + color + ';color:#000}';
          }

          function search(query) {
            const needle = query.toLowerCase(), found = [];
            const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
              acceptNode: node => node.parentElement && !node.parentElement.closest('script,style,noscript,template,head')
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
            });
            while (walker.nextNode()) {
              const node = walker.currentNode, text = node.data.toLowerCase();
              for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) {
                const range = new Range();
                range.setStart(node, i);
                range.setEnd(node, i + needle.length);
                if (range.getClientRects().length) found.push(range);  // skip hidden text
              }
            }
            return found;
          }

          // Briefly scales a copy of the current match up and back, then fades it into the highlight.
          function pop(range) {
            if (popHost) popHost.remove();
            const rect = range.getBoundingClientRect();
            if (!rect.width || !rect.height) return;
            const parentStyle = getComputedStyle(range.startContainer.parentElement);
            popHost = document.createElement('div');
            popHost.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
            const root = popHost.attachShadow({ mode: 'closed' });
            const bubble = document.createElement('div');
            bubble.textContent = range.toString();
            bubble.style.cssText =
              'position:fixed;box-sizing:content-box;white-space:pre;color:#000;border-radius:4px;padding:1px 3px;' +
              'box-shadow:0 2px 8px rgba(0,0,0,.35);' +
              'left:' + (rect.left - 3) + 'px;top:' + (rect.top - 1) + 'px;line-height:' + rect.height + 'px;' +
              'font:' + parentStyle.font + ';background:' + popColor + ';';
            root.appendChild(bubble);
            document.documentElement.appendChild(popHost);
            const host = popHost;
            bubble.animate(
              [{ transform: 'scale(1)' }, { transform: 'scale(1.35)', offset: 0.4 }, { transform: 'scale(1)' }],
              { duration: 280, easing: 'ease-out' }
            ).finished.then(() => bubble.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 350, delay: 500, fill: 'forwards' }).finished)
              .then(() => host.remove(), () => host.remove());
          }

          function show() {
            CSS.highlights.set('browser-find', new Highlight(...ranges));
            if (index < 0) { CSS.highlights.delete('browser-find-current'); return; }
            const current = ranges[index];
            CSS.highlights.set('browser-find-current', new Highlight(current));
            const rect = current.getBoundingClientRect();
            if (rect.top < 0 || rect.bottom > innerHeight || rect.left < 0 || rect.right > innerWidth) {
              current.startContainer.parentElement.scrollIntoView({ block: 'center', inline: 'nearest' });
            }
            pop(current);
          }

          const status = () => ({ index: index + 1, count: ranges.length });

          window.__browserFind = {
            start(query, color) {
              applyColor(color);
              ranges = query ? search(query) : [];
              // Begin at the first match that isn't above the viewport.
              index = ranges.length ? Math.max(0, ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0)) : -1;
              show();
              return status();
            },
            step(delta) {
              if (!ranges.length) return status();
              index = (index + delta + ranges.length) % ranges.length;
              show();
              return status();
            },
            clear() {
              if (popHost) popHost.remove();
              ranges = [];
              index = -1;
              CSS.highlights.delete('browser-find');
              CSS.highlights.delete('browser-find-current');
            },
          };
        })();
        """#
}
