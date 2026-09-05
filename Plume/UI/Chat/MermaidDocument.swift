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

    static func html(source: String, isDark: Bool, foregroundHex: String) -> String {
        let theme = isDark ? "dark" : "default"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; color: \(foregroundHex); }
          #diagram { display: inline-block; }
          #diagram svg { max-width: 100%; height: auto; display: block; }
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
            var box = document.getElementById('diagram').getBoundingClientRect();
            post({ kind: 'rendered', height: Math.ceil(box.height) });
          }
          try {
            mermaid.initialize({ startOnLoad: false, theme: '\(theme)', securityLevel: 'strict' });
            mermaid.render('generated', \(jsString(source))).then(function (result) {
              document.getElementById('diagram').innerHTML = result.svg;
              requestAnimationFrame(report);
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
