// Independent measurement fixture, NOT the original application or its runtime layout.
// xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library scripts/original-layout-reference.swift -o .build/original-layout-reference
// .build/original-layout-reference [--compact] [--dark]
import AppKit
import WebKit

@main
@MainActor
private final class OriginalLayoutReference: NSObject, WKNavigationDelegate {
    private let templateURL = URL(
        fileURLWithPath:
            "/Volumes/CheatSheet/CheatSheet.app/Contents/Resources/template.html")
    private var webView: WKWebView!
    private var window: NSWindow!
    private var finished = false
    private var failure: Error?
    private var output: URL!
    private var report: [String: Any] = [:]

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let reference = OriginalLayoutReference()
        try reference.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while !reference.finished && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard reference.finished else { throw CheckFailure("Offscreen WebKit timed out after 20 seconds") }
        if let error = reference.failure { throw error }
        withExtendedLifetime(reference) {}
    }

    private func start() throws {
        let compact = CommandLine.arguments.contains("--compact")
        let dark = CommandLine.arguments.contains("--dark")
        let width = compact ? 760 : 1000
        // Fixture-only height budget; 48 is the nib footer, NOT a proven runtime constraint.
        let height = (compact ? 430 : 620) - 48
        let suffix = (compact ? "-compact" : "") + (dark ? "-dark" : "")
        output = URL(fileURLWithPath: ".build/original-layout-reference\(suffix)")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        guard let start = template.range(of: "<style type=\"text/css\">"),
            let end = template.range(of: "</style>", range: start.upperBound..<template.endIndex)
        else { throw CheckFailure("Missing template style block") }
        // Read CSS at runtime only. Never load the original script, HTML, or embedded edit-icon asset.
        var css = String(template[start.upperBound..<end.lowerBound])

        css = css.components(separatedBy: .newlines)
            .filter { !$0.contains("background-image:") }.joined(separator: "\n")
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var colors: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            colors = [
                "<textcolor/>": Self.cssColor(.labelColor),
                "<lighttextcolor/>": Self.cssColor(.secondaryLabelColor),
                "<separatorcolor/>": Self.cssColor(.separatorColor),
                "background": Self.cssColor(.windowBackgroundColor),
            ]
        }
        for token in ["<textcolor/>", "<lighttextcolor/>", "<separatorcolor/>"] {
            css = css.replacingOccurrences(of: token, with: colors[token]!)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = webView
        // Never order the window onscreen. CSP denies every resource except our inline CSS/measurement JS.
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
            <style>\(css)
            /* Added fixture constraints: not recovered original runtime behavior. */
            html { background: \(colors["background"]!); color-scheme: \(dark ? "dark" : "light"); }
            .columns { height: \(height)px; column-fill: auto; }
            </style></head><body><div class="columns">\(Self.fixtureHTML)</div></body></html>
            """
        report = [
            "source": templateURL.path,
            "environment": ProcessInfo.processInfo.operatingSystemVersionString,
            "appearance": dark ? "darkAqua" : "aqua",
            "viewport": ["width": width, "height": height],
            "colors": colors,
            "approximations": [
                "Modern WKWebView, standards-mode scaffold, independent fake menus; not original WebView runtime",
                "Fixed height = fixture panel height minus nib footer 48; column-fill:auto added",
                "Color placeholders mapped to current AppKit semantic colors; original mapping unknown",
                "No footer, window chrome, links, hover edit asset, or original script",
                "CSS itself does not establish the original runtime height or scrolling policy",
            ],
        ]
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func cssColor(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB)!
        return
            "rgba(\(rgb.redComponent * 255),\(rgb.greenComponent * 255),\(rgb.blueComponent * 255),\(rgb.alphaComponent))"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.measurement) { [self] value, error in
            do {
                if let error { throw error }
                guard let json = value as? String,
                    let data = json.data(using: .utf8),
                    let metrics = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let checks = metrics["checks"] as? [String: Bool]
                else { throw CheckFailure("Missing WebKit geometry") }
                report["measurement"] = metrics
                let failed = checks.filter { !$0.value }.keys.sorted()
                report["passed"] = failed.isEmpty
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathExtension("json"))
                guard failed.isEmpty else {
                    throw CheckFailure("Geometry checks failed: \(failed.joined(separator: ", "))")
                }
                print("PASS: \(checks.count) geometry checks; \(output.appendingPathExtension("json").path)")
                takeSnapshot()
            } catch { finish(error) }
        }
    }

    private func takeSnapshot() {
        let options = WKSnapshotConfiguration()
        options.rect = webView.bounds
        webView.takeSnapshot(with: options) { [self] image, error in
            do {
                if let error { throw error }
                guard let tiff = image?.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { throw CheckFailure("Offscreen snapshot unavailable; JSON geometry remains valid") }
                try png.write(to: output.appendingPathExtension("png"))
                print(
                    "PNG: \(output.appendingPathExtension("png").path) (\(bitmap.pixelsWide) × \(bitmap.pixelsHigh) pixels)"
                )
                finish(nil)
            } catch { finish(error) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        failure = error
        finished = true
    }

    private static var fixtureHTML: String {
        // Independent fixture with the same menu labels/keys as render-overlay.swift; no dependency on app sources.
        let menus: [(String, [String])] = [
            (
                "Preview Editor",
                ["About Preview Editor", "Settings…", "Hide Preview Editor", "Hide Others", "Quit Preview Editor"]
            ),
            (
                "File",
                [
                    "New File", "New Window", "Open…", "Open Recent", "Close Editor", "Close Window", "Save",
                    "Save As…", "Save All", "Revert File", "Export…", "Print…",
                ]
            ),
            ("Edit", ["Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All"]),
            (
                "Selection — an intentionally long menu title",
                (1...35).map { "Expand Selection to Matching Bracket \($0)" }
            ),
            ("View", ["Show Sidebar", "Show Inspector", "Toggle Full Screen", "Zoom In", "Zoom Out"]),
            ("Navigate", ["Go to File…", "Go to Symbol…", "Jump to Definition", "Go Back", "Go Forward"]),
            ("Window", ["Minimize", "Zoom", "Bring All to Front"]),
            ("Help", ["Search Documentation", "Keyboard Shortcuts"]),
        ]
        let combinations = [
            ("⌘", "N"), ("⇧⌘", "N"), ("⌃⌥⇧⌘", "F12"), ("⌥⌘", "←"), ("⌘", "W"), ("⇧⌘", "W"), ("⌘", "S"), ("⇧⌘", "S"),
            ("⌃⌥⌘", "↩"), ("⌘", "⌫"),
        ]
        return menus.enumerated().map { section, menu in
            let rows = menu.1.enumerated().map { row, title in
                let (modifiers, key) = combinations[row % combinations.count]
                let keyClass = key == "F12" ? "longKey" : "key"
                return
                    "<div class='fixture-row' data-section='\(section)' data-row='\(row)'><span class='short'>\(modifiers)<span class='\(keyClass)'>\(key)</span></span><span class='name'>\(escape(title))</span></div>"
            }.joined()
            return
                "<div class='group'><div class='bold'><span class='short'>&nbsp;</span><span class='fixture-heading'>\(escape(menu.0))</span></div>\(rows)</div>"
        }.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let measurement = #"""
        (() => {
            const rect = element => {
                const r = element.getBoundingClientRect();
                return { x:r.x, y:r.y, width:r.width, height:r.height };
            };
            const near = (a,b) => Math.abs(a-b) < 0.05;
            const columns = document.querySelector('.columns');
            const style = getComputedStyle(columns);
            const rows = [...document.querySelectorAll('.fixture-row')];
            const first = rows[0], second = rows[1];
            const short = first.querySelector('.short'), key = first.querySelector('.key');
            const name = first.querySelector('.name');
            const heading = document.querySelector('.bold');
            const longKey = document.querySelector('.longKey');
            const expectedWidth = (innerWidth - 2*16 - 3*20) / 4;
            // First three groups fit the fixture height individually, so test their real column pitch.
            const groups = [...document.querySelectorAll('.group')];
            const groupOrigins = [...new Set(groups.slice(0,3).map(g => rect(g).x))].sort((a,b) => a-b);
            const measuredPitch = groupOrigins[1] - groupOrigins[0];
            const checks = {
                bodyMargins: near(rect(columns).x,16) && near(rect(columns).width,innerWidth-32),
                font13: near(parseFloat(getComputedStyle(document.body).fontSize),13),
                fourColumns: style.columnCount === '4',
                columnWidthFormula: near(rect(first).width,expectedWidth),
                columnGap20: near(parseFloat(style.columnGap),20) && near(measuredPitch-rect(first).width,20),
                columnRule1: near(parseFloat(style.columnRuleWidth),1) && style.columnRuleStyle === 'solid',
                short74: near(rect(short).width,74),
                gutter78: near(rect(name).x-rect(first).x,78),
                key18: near(rect(key).width,18),
                longKey30: near(rect(longKey).width,30),
                keyRightAlignedInShort: near(rect(key).x+rect(key).width,rect(short).x+74),
                rowLine22: near(rect(first).height,22) && near(rect(second).y-rect(first).y,22),
                headingPadding16: near(parseFloat(getComputedStyle(heading).paddingTop),16),
                headingHeight38: near(rect(heading).height,38),
                headingAlignedWithName: near(rect(document.querySelector('.fixture-heading')).x,rect(name).x),
                groupAvoidBreak: getComputedStyle(groups[0]).webkitColumnBreakInside === 'avoid'
            };
            return JSON.stringify({ checks, expectedWidth, measuredPitch,
                devicePixelRatio, fontFamily:getComputedStyle(document.body).fontFamily,
                columns:rect(columns), firstRow:rect(first), short:rect(short), key:rect(key),
                longKey:rect(longKey), name:rect(name), heading:rect(heading),
                groups:groups.map(g => ({ title:g.querySelector('.fixture-heading').textContent,
                    rects:[...g.getClientRects()].map(r => ({x:r.x,y:r.y,width:r.width,height:r.height})) })),
                rows:rows.map(r => ({section:Number(r.dataset.section), row:Number(r.dataset.row), rect:rect(r),
                    short:rect(r.querySelector('.short')), key:rect(r.querySelector('.key,.longKey')),
                    name:rect(r.querySelector('.name')),
                    nameOffset:rect(r.querySelector('.name')).x-rect(r).x,
                    keyOffsetY:rect(r.querySelector('.key,.longKey')).y-rect(r).y })),
                // These adversarial-fixture observations are not assertions about the original runtime.
                floatAnomalies:rows.filter(r => !near(rect(r.querySelector('.name')).x-rect(r).x,78)
                    || !near(rect(r.querySelector('.key,.longKey')).y,rect(r).y))
                    .map(r => ({section:Number(r.dataset.section),row:Number(r.dataset.row)})),
                scrollWidth:document.documentElement.scrollWidth, scrollHeight:document.documentElement.scrollHeight
            });
        })()
        """#

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
