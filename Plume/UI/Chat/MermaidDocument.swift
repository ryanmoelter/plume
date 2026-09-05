import Foundation

/// The HTML page a `MermaidView` loads to draw one diagram.
///
/// Pure so the template is testable without a web view: everything that
/// varies — the source, the appearance, the colors — is an argument.
nonisolated enum MermaidDocument {
    /// The fence languages that mean "draw this", rather than "show this".
    static let fenceLanguages: Set<String> = ["mermaid"]

    static func isMermaidFence(language: String?) -> Bool {
        guard let language else { return false }
        return fenceLanguages.contains(language.lowercased())
    }

    /// The name the page posts its rendered height and its errors under.
    static let messageHandlerName = "plumeMermaid"

    /// How the drawn SVG relates to the space the page is given.
    enum Sizing {
        /// The SVG keeps its natural height and the page reports it, so the
        /// row can take an explicit frame and stop resizing.
        case natural
        /// The SVG scales down to fit the viewport in both axes. The page
        /// still reports, but the host already knows its own height.
        case fit
        /// Same initial layout as `.fit`, but the page allows itself to
        /// overflow instead of clipping. `WKWebView` magnification scales the
        /// whole page, so once zoomed past 1x the page grows past its
        /// viewport — this is what lets a two-finger scroll pan the zoomed
        /// result instead of the page just clipping it. Scrollbars are
        /// hidden and bounce is disabled so magnification 1.0 still looks
        /// exactly like `.fit`.
        case fitZoomable
    }

    static func html(
        source: String,
        isDark: Bool,
        foregroundHex: String,
        sizing: Sizing = .natural
    ) -> String {
        let theme = isDark ? "dark" : "default"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: \(foregroundHex);
            \(overflowCSS(sizing: sizing))
          }
          \(layoutCSS(sizing: sizing))
        </style>
        <script src="mermaid.min.js"></script>
        </head>
        <body><div id="diagram"></div>
        <script>
        (function () {
          function post(payload) {
            window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload);
          }
          function report() {
            // The SVG's own box, not the wrapper's, which fills the page in
            // fit mode and so measures the container rather than the diagram.
            var diagram = document.getElementById('diagram');
            var drawn = diagram.querySelector('svg') || diagram;
            var box = drawn.getBoundingClientRect();
            post({
              kind: 'rendered',
              height: Math.ceil(box.height),
              width: Math.ceil(box.width),
              viewportWidth: Math.ceil(document.documentElement.clientWidth),
              viewportHeight: Math.ceil(document.documentElement.clientHeight)
            });
          }
          try {
            mermaid.initialize({ startOnLoad: false, theme: '\(theme)', securityLevel: 'strict' });
            mermaid.render('generated', \(jsString(source))).then(function (result) {
              document.getElementById('diagram').innerHTML = result.svg;
              requestAnimationFrame(report);
              // A sheet measures zero while it animates in, so report again
              // once its viewport has settled as well as on any later resize.
              if (window.ResizeObserver) {
                new ResizeObserver(function () {
                  requestAnimationFrame(report);
                }).observe(document.documentElement);
              }
              window.addEventListener('resize', function () {
                requestAnimationFrame(report);
              });
            }).catch(function (error) {
              post({ kind: 'error', message: String((error && error.message) || error) });
            });
          } catch (error) {
            post({ kind: 'error', message: String((error && error.message) || error) });
          }
        })();
        </script>
        </body></html>
        """
    }

    /// The page must have nothing of its own to scroll in `.natural` and
    /// `.fit`, so a wheel event over the diagram is left for the chat list.
    /// `.fitZoomable` is the fullscreen sheet's own `WKWebView`, which is
    /// meant to pan once magnification grows the page past its viewport, so
    /// it allows overflow instead — with its scrollbar hidden and bounce
    /// disabled so magnification 1.0 still looks exactly like `.fit`.
    private static func overflowCSS(sizing: Sizing) -> String {
        switch sizing {
        case .natural, .fit:
            return """
            overflow: hidden;
                -webkit-overflow-scrolling: auto;
                overscroll-behavior: none;
            """
        case .fitZoomable:
            return """
            overflow: auto;
                overscroll-behavior: none;
                scrollbar-width: none;
            """
        }
    }

    /// All three modes center the diagram; they differ in whether the SVG
    /// keeps its natural height or scales to the space the page is given.
    ///
    /// `body` is the flex container rather than `#diagram` so the centering
    /// survives an SVG narrower than the page, which is the common case.
    private static func layoutCSS(sizing: Sizing) -> String {
        switch sizing {
        case .natural:
            return """
            body { display: flex; justify-content: center; }
              #diagram { display: block; max-width: 100%; }
              #diagram svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
            """
        case .fit, .fitZoomable:
            return """
            html, body { width: 100%; height: 100%; }
              body { display: flex; align-items: center; justify-content: center; }
              #diagram { display: block; width: 100%; height: 100%; }
              /* Mermaid emits width="100%" with no height attribute and its
                 own `max-width` cap, so the SVG's height follows only from
                 the viewBox aspect ratio. Filling both axes and letting
                 `object-fit` letterbox it is what scales it to the panel. */
              #diagram svg {
                width: 100%;
                height: 100%;
                max-width: none;
                max-height: none;
                object-fit: contain;
                display: block;
              }
              /* Hides the scrollbar for `.fitZoomable`; a no-op elsewhere
                 since nothing overflows there. */
              ::-webkit-scrollbar { display: none; }
            """
        }
    }

    /// The source as a JavaScript string literal. JSON's escaping is a subset
    /// of JavaScript's, so encoding a one-element array and dropping its
    /// brackets is correct without a hand-rolled escaper.
    ///
    /// `<` is escaped past what JSON needs: the literal sits inside a
    /// `<script>` element, where a `</script>` in the source would close the
    /// block early and the rest would parse as markup.
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode([text]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
    }
}
