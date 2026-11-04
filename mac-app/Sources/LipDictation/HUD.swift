import AVFoundation
import AppKit
import SwiftUI

/// The floating pill at the bottom of the screen: a small view of your face while
/// listening, then "Reading…", then what was typed.
final class HUDController: ObservableObject {
    enum Content: Equatable {
        case starting
        case listening(since: Date, faceOK: Bool)
        case reading
        case done(text: String, copied: Bool)
        case message(symbol: String, text: String, tint: Color)
    }

    @Published private(set) var content: Content?
    var session: AVCaptureSession?
    var showPreview = true
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ c: Content) {
        content = c
        let panel = self.panel ?? makePanel()
        self.panel = panel
        hideWork?.cancel()
        if panel.alphaValue < 1 || !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        position()
        switch c {
        case .done(let text, _): hide(after: min(4.5, 1.6 + Double(text.count) / 40))
        case .message: hide(after: 2.6)
        default: break
        }
    }

    func updateFace(_ ok: Bool) {
        if case .listening(let since, _) = content { content = .listening(since: since, faceOK: ok) }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                self?.content = nil
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = NSSize(width: 560, height: 160)
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 18, width: size.width, height: size.height),
                       display: true)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: HUDView(controller: self))
        return p
    }
}

struct HUDView: View {
    @ObservedObject var controller: HUDController

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let content = controller.content {
                HUDPill(content: content, session: controller.showPreview ? controller.session : nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 560, height: 160)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.content)
    }
}

/// One state of the pill. Also used on its own by the snapshot renderer.
struct HUDPill: View {
    let content: HUDController.Content
    var session: AVCaptureSession?

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) { label }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .padding(18)
        .fixedSize()
    }

    private var leadingPadding: CGFloat {
        if case .listening = content, session != nil { return 6 }
        return 16
    }

    @ViewBuilder private var leading: some View {
        switch content {
        case .starting:
            ProgressView().controlSize(.small).frame(width: 22)
        case .listening(_, let faceOK):
            if let session {
                CameraPreview(session: session)
                    .frame(width: 54, height: 40)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(faceOK ? Color.red.opacity(0.9) : Color.orange, lineWidth: 2))
            } else {
                PulsingDot()
            }
        case .reading:
            ProgressView().controlSize(.small).frame(width: 22)
        case .done(_, let copied):
            Image(systemName: copied ? "doc.on.clipboard.fill" : "checkmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.green)
        case .message(let symbol, _, let tint):
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder private var label: some View {
        switch content {
        case .starting:
            Text("Starting camera…").font(.system(size: 14, weight: .medium))
        case .listening(let since, let faceOK):
            HStack(spacing: 8) {
                if session != nil { PulsingDot() }
                Text(faceOK ? "Listening" : "Can't see your mouth").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(faceOK ? Color.primary : Color.orange)
                TimelineView(.periodic(from: since, by: 0.5)) { ctx in
                    Text(Self.elapsed(ctx.date.timeIntervalSince(since)))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(faceOK ? "Mouth your words, then let go · Esc cancels" : "Face the camera with your mouth in view")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .reading:
            Text("Reading your lips…").font(.system(size: 14, weight: .medium))
        case .done(let text, let copied):
            Text(text).font(.system(size: 14, weight: .medium)).lineLimit(2).frame(maxWidth: 440, alignment: .leading)
            if copied { Text("Copied to the clipboard").font(.system(size: 11)).foregroundStyle(.secondary) }
        case .message(_, let text, _):
            Text(text).font(.system(size: 14, weight: .medium)).lineLimit(2).frame(maxWidth: 440, alignment: .leading)
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Live camera view, mirrored like a mirror.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer = v.preview
        v.wantsLayer = true
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        if let c = v.preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        return v
    }

    func updateNSView(_ v: PreviewView, context: Context) {
        if v.preview.session !== session { v.preview.session = session }
    }

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
    }
}
