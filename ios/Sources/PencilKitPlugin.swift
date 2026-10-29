import UIKit
import PencilKit
import WebKit
import Tauri

// MARK: - Bridged Undo Manager
@available(iOS 14.0, *)
public class BridgedUndoManager: UndoManager {
    public weak var plugin: PencilKitPlugin?
    public var bridgedCanUndo: Bool = false
    public var bridgedCanRedo: Bool = false

    public override var canUndo: Bool {
        return bridgedCanUndo
    }

    public override var canRedo: Bool {
        return bridgedCanRedo
    }

    public override func undo() {
        plugin?.handleNativeUndo()
    }

    public override func redo() {
        plugin?.handleNativeRedo()
    }
}

// MARK: - Passthrough Canvas View
@available(iOS 14.0, *)
public class PassthroughPKCanvasView: PKCanvasView {
    public weak var plugin: PencilKitPlugin?
    public let customUndoManager = BridgedUndoManager()
    public var isPencilActive: Bool = false
    public var isEraserActive: Bool = false
    public var topChromeHeight: CGFloat = 128.0
    public var excludedRects: [CGRect] = []

    public override var undoManager: UndoManager? {
        return customUndoManager
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.backgroundColor = .clear
        self.isOpaque = false
        self.isScrollEnabled = false
        self.drawingPolicy = .pencilOnly
        self.isHidden = true
        self.customUndoManager.disableUndoRegistration()
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) || action == #selector(UndoManager.undo) {
            return customUndoManager.canUndo
        }
        if action == #selector(redo(_:)) || action == #selector(UndoManager.redo) {
            return customUndoManager.canRedo
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc public func undo(_ sender: Any?) {
        plugin?.handleNativeUndo()
    }

    @objc public func redo(_ sender: Any?) {
        plugin?.handleNativeRedo()
    }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isPencilActive else { return nil }
        if !self.point(inside: point, with: event) {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    /// Direct touch routing:
    /// Apple Pencil touches stay on PKCanvasView for native 120/240Hz Metal drawing.
    /// When eraser is active, pencil touches pass through to WKWebView so web-layer
    /// vector hit-testing erases existing strokes in real time.
    /// Finger touches pass straight through to the underlying WKWebView for scrolling and buttons.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isPencilActive else { return false }
        if isEraserActive {
            return false
        }

        // 1. Never capture touches over the top navigation and toolbar chrome.
        // Tapping the Markup/Done button, Back, Tabs, or Zoom menu passes through to WKWebView.
        let topCutoff = max(self.topChromeHeight, self.safeAreaInsets.top)
        if point.y <= topCutoff {
            plugin?.commitAndClearScratchpad(self)
            return false
        }

        // 2. Never capture touches over registered active popovers, dialogs, or dropdowns
        for rect in excludedRects {
            if rect.contains(point) {
                plugin?.commitAndClearScratchpad(self)
                return false
            }
        }

        // 3. Finger touches pass through to the underlying WKWebView for scrolling.
        // Flush any pending scratchpad strokes immediately so they move with the document.
        if let touches = event?.allTouches, !touches.isEmpty {
            let hasPencil = touches.contains(where: { $0.type == .pencil })
            if !hasPencil {
                // All touches are fingers: pass through to WKWebView for one/two-finger scroll
                plugin?.commitAndClearScratchpad(self)
                return false
            } else {
                // Apple Pencil touch down: synchronously halt any pending commit timer
                plugin?.pencilTouchDidBegin()
                return true
            }
        }
        return true
    }
}

// MARK: - Tool Configuration Models
public struct ToolItemConfig: Equatable {
    public var enabled: Bool
    public var color: String?
    public var width: CGFloat?

    public init(enabled: Bool = true, color: String? = nil, width: CGFloat? = nil) {
        self.enabled = enabled
        self.color = color
        self.width = width
    }
}

public struct EraserToolConfig: Equatable {
    public var enabled: Bool
    public var type: String // "vector" or "bitmap"
    public var width: CGFloat?

    public init(enabled: Bool = true, type: String = "vector", width: CGFloat? = nil) {
        self.enabled = enabled
        self.type = type
        self.width = width
    }
}

public struct ToolPickerConfig: Equatable {
    public var pen: ToolItemConfig
    public var pencil: ToolItemConfig
    public var marker: ToolItemConfig
    public var eraser: EraserToolConfig
    public var lasso: Bool
    public var ruler: Bool
    public var allowsColorSelection: Bool

    public init(
        pen: ToolItemConfig = ToolItemConfig(enabled: true, color: "blue", width: 3.5),
        pencil: ToolItemConfig = ToolItemConfig(enabled: false),
        marker: ToolItemConfig = ToolItemConfig(enabled: true, color: "yellow", width: 24.0),
        eraser: EraserToolConfig = EraserToolConfig(enabled: false, type: "vector"),
        lasso: Bool = false,
        ruler: Bool = false,
        allowsColorSelection: Bool = false
    ) {
        self.pen = pen
        self.pencil = pencil
        self.marker = marker
        self.eraser = eraser
        self.lasso = lasso
        self.ruler = ruler
        self.allowsColorSelection = allowsColorSelection
    }
}

// MARK: - Tauri Plugin
@available(iOS 14.0, *)
public class PencilKitPlugin: Plugin, PKCanvasViewDelegate, PKToolPickerObserver, UIPencilInteractionDelegate {
    private weak var webView: WKWebView?
    private var canvasView: PassthroughPKCanvasView?
    private var toolPicker: PKToolPicker?
    private var pencilInteraction: UIPencilInteraction?
    private var currentToolConfig = ToolPickerConfig()
    private var configuredPickerConfig: ToolPickerConfig?

    // Active document state
    private var isPencilModeActive: Bool = false
    private var currentFile: String = ""
    private var currentAuthorWidth: CGFloat = 800.0
    private var currentTargetWidth: CGFloat = 800.0
    private var currentTargetRect: CGRect = .zero
    private var activeMarkupTool: String = "marker"
    private var activeMarkupColor: String = "blue"

    // Scratchpad idle debounce commit state:
    // While writing in quick succession, strokes accumulate smoothly in PKCanvasView.
    // When writing pauses (1.0s idle), all accumulated strokes are exported and the scratchpad is cleared.
    private var isCurrentlyDrawing: Bool = false
    private var commitTimer: Timer?
    private let commitDelay: TimeInterval = 1.0

    public override func load(webview: WKWebView) {
        self.webView = webview

        DispatchQueue.main.async { [weak self, weak webview] in
            guard let self = self, let webview = webview else { return }

            let canvas = PassthroughPKCanvasView(frame: webview.bounds)
            canvas.plugin = self
            canvas.customUndoManager.plugin = self
            canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            canvas.delegate = self

            // Apple Pencil hardware interaction (e.g. double-tap on Pencil 2 / Pencil Pro)
            let interaction = UIPencilInteraction()
            interaction.delegate = self
            canvas.addInteraction(interaction)
            self.pencilInteraction = interaction

            webview.superview?.insertSubview(canvas, aboveSubview: webview)
            self.canvasView = canvas

            // Initialize tool picker with the configured tools (pencil, marker, eraser; pen/lasso/ruler hidden; color picker removed)
            self.setupToolPicker(with: self.currentToolConfig)

            webview.evaluateJavaScript("window.__pencilKitReady = true;")
        }
    }

    private func setupToolPicker(with config: ToolPickerConfig) {
        // Unchanged-config early-exit: avoids re-parsing config and tearing down/rebuilding
        // the picker on iOS 18, which also fully closes the closed-race trigger.
        if self.toolPicker != nil && self.configuredPickerConfig == config {
            if isPencilModeActive, let canvas = self.canvasView {
                self.toolPicker?.setVisible(true, forFirstResponder: canvas)
            }
            return
        }

        self.configuredPickerConfig = config
        self.currentToolConfig = config

        if #available(iOS 18.0, *) {
            var items: [PKToolPickerItem] = []

            if config.pen.enabled {
                let color = resolveColor(from: config.pen.color ?? "blue")
                let width = config.pen.width ?? 3.5
                let penItem = PKToolPickerInkingItem(type: .pen, color: color, width: width)
                penItem.allowsColorSelection = config.allowsColorSelection
                items.append(penItem)
            }

            if config.pencil.enabled {
                let color = resolveColor(from: config.pencil.color ?? "blue")
                let width = config.pencil.width ?? 3.5
                let penItem = PKToolPickerInkingItem(type: .pen, color: color, width: width)
                penItem.allowsColorSelection = config.allowsColorSelection
                items.append(penItem)
            }

            if config.marker.enabled {
                let color = resolveColor(from: config.marker.color ?? "yellow")
                let width = config.marker.width ?? 24.0
                let markerItem = PKToolPickerInkingItem(type: .marker, color: color, width: width)
                markerItem.allowsColorSelection = config.allowsColorSelection
                items.append(markerItem)
            }

            if config.eraser.enabled {
                if config.eraser.type == "bitmap" {
                    let eraserItem = PKToolPickerEraserItem(type: .bitmap)
                    items.append(eraserItem)
                } else {
                    let eraserItem = PKToolPickerEraserItem(type: .vector)
                    items.append(eraserItem)
                }
            }

            if config.lasso {
                let lassoItem = PKToolPickerLassoItem()
                items.append(lassoItem)
            }

            if config.ruler {
                let rulerItem = PKToolPickerRulerItem()
                items.append(rulerItem)
            }

            // Fallback: ensure at least pen & marker exist if all were disabled
            if items.isEmpty {
                let fallbackPen = PKToolPickerInkingItem(type: .pen, color: resolveColor(from: self.activeMarkupColor), width: 3.5)
                fallbackPen.allowsColorSelection = config.allowsColorSelection
                items.append(fallbackPen)
                let fallbackMarker = PKToolPickerInkingItem(type: .marker, color: resolveColor(from: "yellow"), width: 24.0)
                fallbackMarker.allowsColorSelection = config.allowsColorSelection
                items.append(fallbackMarker)
            }

            if let oldPicker = self.toolPicker {
                // Remove self as observer FIRST before hiding oldPicker
                // so toolPickerVisibilityDidChange is NOT triggered on picker replacement!
                oldPicker.removeObserver(self)
                if let canvas = self.canvasView {
                    oldPicker.removeObserver(canvas)
                    oldPicker.setVisible(false, forFirstResponder: canvas)
                }
            }

            let picker = PKToolPicker(toolItems: items)
            picker.showsDrawingPolicyControls = false
            picker.isRulerActive = false
            picker.addObserver(self)
            if let canvas = self.canvasView {
                canvas.isRulerActive = false
                picker.addObserver(canvas)
            }
            self.toolPicker = picker

            if isPencilModeActive, let canvas = self.canvasView {
                picker.setVisible(true, forFirstResponder: canvas)
            }
        } else {
            // iOS 14 - 17 fallback
            if self.toolPicker == nil {
                let picker = PKToolPicker()
                picker.showsDrawingPolicyControls = false
                picker.isRulerActive = false
                picker.addObserver(self)
                if let canvas = self.canvasView {
                    canvas.isRulerActive = false
                    picker.addObserver(canvas)
                }
                self.toolPicker = picker
            }
        }
    }

    private func parseToolConfig(from dict: [String: Any]) -> ToolPickerConfig {
        var config = self.currentToolConfig

        if let penDict = dict["pen"] as? [String: Any] {
            config.pen.enabled = penDict["enabled"] as? Bool ?? true
            if let c = penDict["color"] as? String { config.pen.color = c }
            if let w = penDict["width"] as? Double { config.pen.width = CGFloat(w) }
        } else if let penBool = dict["pen"] as? Bool {
            config.pen.enabled = penBool
        }

        if let pencilDict = dict["pencil"] as? [String: Any] {
            config.pencil.enabled = pencilDict["enabled"] as? Bool ?? true
            if let c = pencilDict["color"] as? String { config.pencil.color = c }
            if let w = pencilDict["width"] as? Double { config.pencil.width = CGFloat(w) }
        } else if let pencilBool = dict["pencil"] as? Bool {
            config.pencil.enabled = pencilBool
        }

        if let markerDict = dict["marker"] as? [String: Any] {
            config.marker.enabled = markerDict["enabled"] as? Bool ?? true
            if let c = markerDict["color"] as? String { config.marker.color = c }
            if let w = markerDict["width"] as? Double { config.marker.width = CGFloat(w) }
        } else if let markerBool = dict["marker"] as? Bool {
            config.marker.enabled = markerBool
        }

        if let eraserDict = dict["eraser"] as? [String: Any] {
            config.eraser.enabled = eraserDict["enabled"] as? Bool ?? true
            if let t = eraserDict["type"] as? String { config.eraser.type = t }
            if let w = eraserDict["width"] as? Double { config.eraser.width = CGFloat(w) }
        } else if let eraserBool = dict["eraser"] as? Bool {
            config.eraser.enabled = eraserBool
        }

        if let lassoDict = dict["lasso"] as? [String: Any] {
            config.lasso = lassoDict["enabled"] as? Bool ?? true
        } else if let lassoBool = dict["lasso"] as? Bool {
            config.lasso = lassoBool
        }

        if let rulerDict = dict["ruler"] as? [String: Any] {
            config.ruler = rulerDict["enabled"] as? Bool ?? true
        } else if let rulerBool = dict["ruler"] as? Bool {
            config.ruler = rulerBool
        }

        if let allowColor = dict["allowsColorSelection"] as? Bool {
            config.allowsColorSelection = allowColor
        }

        return config
    }

    // MARK: - Plugin Commands
    @objc public func isAvailable(_ invoke: Invoke) {
        invoke.resolve(["available": true])
    }

    @objc public func setActive(_ invoke: Invoke) throws {
        let args = try invoke.getArgs()
        let active = args["active"] as? Bool ?? false
        let file = args["file"] as? String ?? ""
        let authorWidth = args["authorWidth"] as? Double ?? 800.0
        let targetWidth = args["targetWidth"] as? Double ?? 800.0
        let rectDict = args["targetRect"] as? [String: Double]
        let topHeight = args["topHeight"] as? Double
        let toolsDict = args["tools"] as? [String: Any]
        let canUndo = args["canUndo"] as? Bool
        let canRedo = args["canRedo"] as? Bool

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPencilModeActive = active
            self.currentFile = file
            self.currentAuthorWidth = authorWidth > 0 ? CGFloat(authorWidth) : 800.0
            self.currentTargetWidth = targetWidth > 0 ? CGFloat(targetWidth) : 800.0

            if let r = rectDict,
               let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] {
                self.currentTargetRect = CGRect(x: x, y: y, width: w, height: h)
            } else {
                self.currentTargetRect = self.webView?.bounds ?? .zero
            }

            if let td = toolsDict {
                let newConfig = self.parseToolConfig(from: td)
                if newConfig != self.currentToolConfig || self.toolPicker == nil {
                    self.setupToolPicker(with: newConfig)
                }
            }

            guard let canvas = self.canvasView else {
                invoke.resolve()
                return
            }

            if let th = topHeight {
                canvas.topChromeHeight = CGFloat(th)
            }

            canvas.isPencilActive = active
            canvas.isHidden = !active

            if let picker = self.toolPicker {
                picker.setVisible(active, forFirstResponder: canvas)
                if active {
                    canvas.becomeFirstResponder()
                } else {
                    canvas.resignFirstResponder()
                }
            }

            if let cu = canUndo {
                canvas.customUndoManager.bridgedCanUndo = cu
            }
            if let cr = canRedo {
                canvas.customUndoManager.bridgedCanRedo = cr
            }
            if canUndo != nil || canRedo != nil {
                NotificationCenter.default.post(
                    name: .NSUndoManagerCheckpoint,
                    object: canvas.customUndoManager
                )
            }

            // Scratchpad: flush and commit any pending strokes before mode/document change
            self.commitAndClearScratchpad(canvas)
            invoke.resolve()
        }
    }

    @objc public func configureTools(_ invoke: Invoke) throws {
        let args = try invoke.getArgs()
        let configDict = (args["tools"] as? [String: Any]) ?? args

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                invoke.resolve()
                return
            }
            self.currentToolConfig = self.parseToolConfig(from: configDict)
            self.setupToolPicker(with: self.currentToolConfig)
            invoke.resolve(["success": true])
        }
    }

    @objc public func setTool(_ invoke: Invoke) throws {
        let args = try invoke.getArgs()
        let toolName = args["tool"] as? String ?? "marker"
        let colorName = args["color"] as? String ?? "blue"
        let width = args["width"] as? Double

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let canvas = self.canvasView else {
                invoke.resolve()
                return
            }

            self.commitAndClearScratchpad(canvas)

            self.activeMarkupTool = toolName
            self.activeMarkupColor = colorName

            let color = self.resolveColor(from: colorName)
            if toolName == "eraser" {
                canvas.isEraserActive = true
                canvas.tool = PKEraserTool(.vector)
            } else if toolName == "highlighter" {
                canvas.isEraserActive = false
                let strokeWidth = width.map { CGFloat($0) } ?? 24.0
                canvas.tool = PKInkingTool(.marker, color: color, width: strokeWidth)
            } else {
                canvas.isEraserActive = false
                let strokeWidth = width.map { CGFloat($0) } ?? 3.5
                canvas.tool = PKInkingTool(.pen, color: color, width: strokeWidth)
            }
            invoke.resolve()
        }
    }

    @objc public func setExcludedRects(_ invoke: Invoke) throws {
        let args = try invoke.getArgs()
        let rectsArray = args["rects"] as? [[String: Double]] ?? []
        let topHeight = args["topHeight"] as? Double

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let canvas = self.canvasView else {
                invoke.resolve()
                return
            }
            if let th = topHeight {
                canvas.topChromeHeight = CGFloat(th)
            }
            var parsedRects: [CGRect] = []
            for r in rectsArray {
                if let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] {
                    parsedRects.append(CGRect(x: x, y: y, width: w, height: h))
                }
            }
            canvas.excludedRects = parsedRects
            invoke.resolve()
        }
    }

    @objc public func clear(_ invoke: Invoke) throws {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.commitTimer?.invalidate()
            self.commitTimer = nil
            self.canvasView?.drawing = PKDrawing()
            invoke.resolve()
        }
    }

    @objc public func syncUndoRedo(_ invoke: Invoke) throws {
        let args = try invoke.getArgs()
        let canUndo = args["canUndo"] as? Bool ?? false
        let canRedo = args["canRedo"] as? Bool ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let canvas = self.canvasView else {
                invoke.resolve(["success": true])
                return
            }
            canvas.customUndoManager.bridgedCanUndo = canUndo
            canvas.customUndoManager.bridgedCanRedo = canRedo

            NotificationCenter.default.post(
                name: .NSUndoManagerCheckpoint,
                object: canvas.customUndoManager
            )
            NotificationCenter.default.post(
                name: .NSUndoManagerDidUndoChange,
                object: canvas.customUndoManager
            )
            NotificationCenter.default.post(
                name: .NSUndoManagerDidRedoChange,
                object: canvas.customUndoManager
            )
            invoke.resolve(["success": true])
        }
    }

    private var lastUndoTimestamp: TimeInterval = 0

    public func handleNativeUndo(source: String = "toolbar") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            if now - self.lastUndoTimestamp < 0.15 {
                return
            }
            self.lastUndoTimestamp = now

            if let canvas = self.canvasView {
                self.commitAndClearScratchpad(canvas)
            }

            let dict: [String: Any] = ["source": source]
            if let jsObj = JSTypes.coerceDictionaryToJSObject(dict) {
                self.trigger("pencilkit:undo", data: jsObj)
            }
        }
    }

    public func handleNativeRedo() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let canvas = self.canvasView {
                self.commitAndClearScratchpad(canvas)
            }

            let dict: [String: Any] = [:]
            if let jsObj = JSTypes.coerceDictionaryToJSObject(dict) {
                self.trigger("pencilkit:redo", data: jsObj)
            }
        }
    }

    // MARK: - UIPencilInteractionDelegate
    public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard isPencilModeActive else { return }
        handleNativeUndo(source: "double-tap")
    }

    @available(iOS 17.5, *)
    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard isPencilModeActive else { return }
        handleNativeUndo(source: "double-tap")
    }

    /// Called synchronously on Apple Pencil hit-test before drawing begins to halt any pending commit timer
    func pencilTouchDidBegin() {
        commitTimer?.invalidate()
        commitTimer = nil
        isCurrentlyDrawing = true
    }

    // MARK: - PKCanvasViewDelegate
    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard isPencilModeActive else { return }
        isCurrentlyDrawing = true
        commitTimer?.invalidate()
        commitTimer = nil
    }

    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard isPencilModeActive else { return }
        isCurrentlyDrawing = false
        scheduleCommitTimer(for: canvasView)
    }

    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard isPencilModeActive else { return }
        if !isCurrentlyDrawing {
            scheduleCommitTimer(for: canvasView)
        }
    }

    private func scheduleCommitTimer(for canvasView: PKCanvasView) {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: commitDelay, repeats: false) { [weak self, weak canvasView] _ in
            guard let self = self, let canvas = canvasView else { return }
            guard !self.isCurrentlyDrawing else { return }
            self.commitAndClearScratchpad(canvas)
        }
    }

    /// Commits all strokes on the scratchpad to the web annotation store and clears the canvas.
    /// Safely guarded: never clears while the user is actively drawing a stroke.
    func commitAndClearScratchpad(_ canvasView: PKCanvasView) {
        commitTimer?.invalidate()
        commitTimer = nil

        guard !isCurrentlyDrawing else { return }

        let strokes = canvasView.drawing.strokes
        guard !strokes.isEmpty else { return }

        for stroke in strokes {
            let strokeData = exportStroke(
                stroke,
                file: currentFile,
                authorWidth: currentAuthorWidth,
                targetWidth: currentTargetWidth,
                targetRect: currentTargetRect
            )
            if strokeData.isEmpty { continue }
            if let jsObj = JSTypes.coerceDictionaryToJSObject(strokeData) {
                self.trigger("pencilkit:stroke-drawn", data: jsObj)
            }
        }

        canvasView.drawing = PKDrawing()
    }

    // MARK: - PKToolPickerObserver
    public func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        if let canvas = self.canvasView {
            self.commitAndClearScratchpad(canvas)
        }

        let tool = toolPicker.selectedTool
        var toolName = "marker"
        var colorName = self.activeMarkupColor
        var toolWidth: Double? = nil
        var toolOpacity: Double? = nil

        if tool is PKEraserTool {
            if !self.currentToolConfig.eraser.enabled {
                // Eraser is removed in our UI: revert back to inking pen tool
                let fallbackTool = PKInkingTool(.pen, color: resolveColor(from: self.activeMarkupColor), width: 3.5)
                toolPicker.selectedTool = fallbackTool
                self.canvasView?.tool = fallbackTool
                return
            }
            toolName = "eraser"
            self.activeMarkupTool = "eraser"
            self.canvasView?.isEraserActive = true
        } else if tool is PKLassoTool {
            if !self.currentToolConfig.lasso {
                // Lasso is removed in our UI: revert back to inking pen tool
                let fallbackTool = PKInkingTool(.pen, color: resolveColor(from: self.activeMarkupColor), width: 3.5)
                toolPicker.selectedTool = fallbackTool
                self.canvasView?.tool = fallbackTool
                return
            }
            toolName = "lasso"
            self.activeMarkupTool = "lasso"
            self.canvasView?.isEraserActive = false
        } else if let inkingTool = tool as? PKInkingTool {
            self.canvasView?.isEraserActive = false
            let isHighlighter = inkingTool.inkType == .marker
            toolName = isHighlighter ? "highlighter" : "marker"
            colorName = mapColorToMarkup(inkingTool.color)
            self.activeMarkupTool = toolName
            self.activeMarkupColor = colorName

            // Extract width scaled to author coordinates and opacity from inking tool
            let scale = self.currentTargetWidth > 0 ? (self.currentAuthorWidth / self.currentTargetWidth) : 1.0
            toolWidth = Double(inkingTool.width * scale)

            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1.0
            if inkingTool.color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                toolOpacity = Double(a)
            }
        }

        var dict: [String: Any] = [
            "tool": toolName,
            "color": colorName
        ]
        if let w = toolWidth {
            dict["width"] = w
        }
        if let o = toolOpacity {
            dict["opacity"] = o
        }

        if let jsObj = JSTypes.coerceDictionaryToJSObject(dict) {
            self.trigger("pencilkit:tool-changed", data: jsObj)
        }
    }

    public func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        // When the user dismisses or hides the native PKToolPicker,
        // commit any remaining strokes and turn off markup mode in the web UI.
        if !toolPicker.isVisible && isPencilModeActive {
            if let canvas = self.canvasView {
                self.commitAndClearScratchpad(canvas)
            }
            self.isPencilModeActive = false
            self.canvasView?.isPencilActive = false
            self.canvasView?.isHidden = true

            let dict: [String: Any] = ["visible": false]
            if let jsObj = JSTypes.coerceDictionaryToJSObject(dict) {
                self.trigger("pencilkit:closed", data: jsObj)
            }
        }
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Stroke Conversion (Apple Official APIs)
    private func exportStroke(
        _ stroke: PKStroke,
        file: String,
        authorWidth: CGFloat,
        targetWidth: CGFloat,
        targetRect: CGRect
    ) -> [String: Any] {
        let scale = targetWidth > 0 ? (authorWidth / targetWidth) : 1.0
        let topCutoff = max(self.canvasView?.topChromeHeight ?? 128.0, self.canvasView?.safeAreaInsets.top ?? 0)

        // 1. Collect points that fall below top chrome/navigation
        var rawPoints: [PKStrokePoint] = []
        for pt in stroke.path {
            if pt.location.y > topCutoff {
                rawPoints.append(pt)
            }
        }

        if rawPoints.isEmpty {
            return [:]
        }

        var viewportPoints: [Double] = []
        var totalWidth: CGFloat = 0
        var totalOpacity: CGFloat = 0
        var validPointsCount: Int = 0

        if rawPoints.count == 1 {
            let pt = rawPoints[0]
            let rx = Double(pt.location.x.rounded())
            let ry = Double(pt.location.y.rounded())
            let forceClamped = Double(max(0.1, min(1.0, pt.force)))
            let rp = (forceClamped * 100.0).rounded() / 100.0
            // Emit a tiny 2-point segment (offset by 0.5 author px) so it renders as a round dot
            viewportPoints = [rx, ry, rp, rx + 0.5, ry + 0.5, rp]
            totalWidth = pt.size.width * 2
            totalOpacity = pt.opacity * 2
            validPointsCount = 2
        } else {
            // 2. Decimate points:
            //    - Keep points >= ~1.3 pt apart
            //    - Keep local pressure extremes if at least min 1 pixel away (>= 1.0 pt)
            //    - Always retain the stroke's initial point and final endpoint
            let minPixelDistSq: CGFloat = 1.0 // 1.0 pt (~2 Retina pixels) minimum step
            let normalDistSq: CGFloat = 1.3 * 1.3 // ~1.69 pt^2 (~1.3 pt threshold)

            var keptPoints: [PKStrokePoint] = []
            keptPoints.reserveCapacity(rawPoints.count)

            // Always keep the starting point
            keptPoints.append(rawPoints[0])

            let count = rawPoints.count
            if count > 2 {
                for i in 1..<(count - 1) {
                    let curr = rawPoints[i]
                    guard let lastKept = keptPoints.last else { continue }

                    let dx = curr.location.x - lastKept.location.x
                    let dy = curr.location.y - lastKept.location.y
                    let distSq = dx * dx + dy * dy

                    // Fast check: points must be at least minPixelDist away
                    if distSq < minPixelDistSq {
                        continue
                    }

                    // If distance is at least 1.3 pt, keep it
                    if distSq >= normalDistSq {
                        keptPoints.append(curr)
                        continue
                    }

                    // Between 1.0 pt and 1.3 pt: keep if it's a significant local pressure extreme
                    let prevForce = rawPoints[i - 1].force
                    let currForce = curr.force
                    let nextForce = rawPoints[i + 1].force

                    let isPeak = currForce > prevForce && currForce > nextForce
                    let isTrough = currForce < prevForce && currForce < nextForce
                    let isSignificant = abs(currForce - prevForce) >= 0.05 || abs(currForce - nextForce) >= 0.05

                    if (isPeak || isTrough) && isSignificant {
                        keptPoints.append(curr)
                    }
                }
            }

            // Always resolve the final stroke endpoint
            let lastRaw = rawPoints[count - 1]
            if let lastKept = keptPoints.last {
                let dx = lastRaw.location.x - lastKept.location.x
                let dy = lastRaw.location.y - lastKept.location.y
                let distSq = dx * dx + dy * dy

                if distSq >= minPixelDistSq {
                    keptPoints.append(lastRaw)
                } else if keptPoints.count > 1 {
                    // If endpoint is within < 1 pixel of the previous kept point, replace it
                    // with the true final stroke endpoint so the stroke terminates accurately
                    keptPoints[keptPoints.count - 1] = lastRaw
                }
            }

            // 3. Round coordinates to whole numbers to drastically shrink persisted JSON
            // and SVG path strings without visual loss, and round pressure to 2 decimals.
            viewportPoints.reserveCapacity(keptPoints.count * 3)

            var lastRoundedX: Double? = nil
            var lastRoundedY: Double? = nil

            for pt in keptPoints {
                let rx = Double(pt.location.x.rounded())
                let ry = Double(pt.location.y.rounded())

                // Avoid emitting duplicate consecutive points after integer rounding
                if let lx = lastRoundedX, let ly = lastRoundedY, lx == rx, ly == ry {
                    continue
                }

                let forceClamped = Double(max(0.1, min(1.0, pt.force)))
                let rp = (forceClamped * 100.0).rounded() / 100.0

                viewportPoints.append(rx)
                viewportPoints.append(ry)
                viewportPoints.append(rp)

                lastRoundedX = rx
                lastRoundedY = ry

                totalWidth += pt.size.width
                totalOpacity += pt.opacity
                validPointsCount += 1
            }

            // If all points collapsed to the same coordinate after integer rounding, ensure valid dot
            if viewportPoints.count < 6 && !rawPoints.isEmpty {
                let pt = rawPoints[0]
                let rx = Double(pt.location.x.rounded())
                let ry = Double(pt.location.y.rounded())
                let forceClamped = Double(max(0.1, min(1.0, pt.force)))
                let rp = (forceClamped * 100.0).rounded() / 100.0
                viewportPoints = [rx, ry, rp, rx + 0.5, ry + 0.5, rp]
                totalWidth = pt.size.width * 2
                totalOpacity = pt.opacity * 2
                validPointsCount = 2
            }
        }

        if viewportPoints.count < 6 {
            return [:]
        }

        let isHighlighter = stroke.ink.inkType == .marker
        let resolvedTool = isHighlighter ? "highlighter" : "marker"
        let resolvedColor = mapColorToMarkup(stroke.ink.color)

        var strokeDict: [String: Any] = [
            "id": UUID().uuidString,
            "file": file,
            "tool": resolvedTool,
            "color": resolvedColor,
            "viewportPoints": viewportPoints,
            "authorWidth": Double(authorWidth),
            "date": Self.isoDateFormatter.string(from: stroke.path.creationDate)
        ]

        if validPointsCount > 0 {
            let avgWidth = totalWidth / CGFloat(validPointsCount)
            if avgWidth > 0 {
                // Width scaled to author px coordinates
                strokeDict["width"] = Double(avgWidth * scale)
            }
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 1.0
        if stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &alpha) {
            strokeDict["opacity"] = Double(alpha)
        } else if validPointsCount > 0 {
            let avgOpacity = totalOpacity / CGFloat(validPointsCount)
            if avgOpacity > 0 {
                strokeDict["opacity"] = Double(avgOpacity)
            }
        }

        return strokeDict
    }

    private struct AppleColorEntry {
        let name: String
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
    }

    private static let applePalette: [AppleColorEntry] = {
        let lightTrait = UITraitCollection(userInterfaceStyle: .light)
        let candidates: [(String, UIColor)] = [
            ("black", .black),
            ("white", .white),
            ("blue", .systemBlue),
            ("green", .systemGreen),
            ("yellow", .systemYellow),
            ("red", .systemRed)
        ]
        return candidates.compactMap { name, color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            let resolved = color.resolvedColor(with: lightTrait)
            if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
                return AppleColorEntry(name: name, r: r, g: g, b: b)
            } else if resolved.getWhite(&r, alpha: &a) {
                return AppleColorEntry(name: name, r: r, g: r, b: r)
            }
            return nil
        }
    }()

    private func resolveColor(from name: String) -> UIColor {
        switch name.lowercased() {
        case "blue": return UIColor(red: 0x00/255.0, green: 0x7a/255.0, blue: 0xff/255.0, alpha: 1.0)
        case "green": return UIColor(red: 0x34/255.0, green: 0xc7/255.0, blue: 0x59/255.0, alpha: 1.0)
        case "yellow": return UIColor(red: 0xff/255.0, green: 0xcc/255.0, blue: 0x00/255.0, alpha: 1.0)
        case "red": return UIColor(red: 0xff/255.0, green: 0x3b/255.0, blue: 0x30/255.0, alpha: 1.0)
        case "black": return UIColor(red: 0x1c/255.0, green: 0x19/255.0, blue: 0x17/255.0, alpha: 1.0)
        case "white": return .white
        case "hl-yellow": return UIColor(red: 0xff/255.0, green: 0xcc/255.0, blue: 0x00/255.0, alpha: 0.8)
        case "hl-green": return UIColor(red: 0x34/255.0, green: 0xc7/255.0, blue: 0x59/255.0, alpha: 0.8)
        case "hl-pink", "pink": return UIColor(red: 0xff/255.0, green: 0x2d/255.0, blue: 0x55/255.0, alpha: 0.8)
        default:
            if name.hasPrefix("#") {
                let hex = name.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                var int: UInt64 = 0
                if Scanner(string: hex).scanHexInt64(&int) {
                    let r = CGFloat((int >> 16) & 0xFF) / 255.0
                    let g = CGFloat((int >> 8) & 0xFF) / 255.0
                    let b = CGFloat(int & 0xFF) / 255.0
                    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
                }
            }
            return UIColor(red: 0x00/255.0, green: 0x7a/255.0, blue: 0xff/255.0, alpha: 1.0)
        }
    }

    private func mapColorToMarkup(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0

        // Resolve dynamic traits in light mode and get sRGB channels
        let srgbColor = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if !srgbColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if srgbColor.getWhite(&white, alpha: &a) {
                r = white; g = white; b = white
            } else {
                return "yellow"
            }
        }

        // Match against Apple's standard colors by distance in RGB space
        var bestMatch: String? = nil
        var minDistanceSq: CGFloat = CGFloat.greatestFiniteMagnitude

        for entry in Self.applePalette {
            let dr = r - entry.r
            let dg = g - entry.g
            let db = b - entry.b
            let distSq = dr * dr + dg * dg + db * db
            if distSq < minDistanceSq {
                minDistanceSq = distSq
                bestMatch = entry.name
            }
        }

        // Distance threshold in RGB space: < 0.05 (~0.22 Euclidean distance)
        // cleanly matches Apple's palette colors even across color space variations
        if let bestMatch = bestMatch, minDistanceSq < 0.05 {
            return bestMatch
        }

        // Fallback for custom/future colors: return exact hex color #RRGGBB
        return String(
            format: "#%02lX%02lX%02lX",
            lroundf(Float(max(0, min(1, r)) * 255.0)),
            lroundf(Float(max(0, min(1, g)) * 255.0)),
            lroundf(Float(max(0, min(1, b)) * 255.0))
        )
    }
}

@_cdecl("init_plugin_pencilkit")
public func initPlugin() -> Plugin {
    if #available(iOS 14.0, *) {
        return PencilKitPlugin()
    } else {
        return Plugin()
    }
}
