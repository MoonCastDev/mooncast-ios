//
//  MCFsrRtc.swift
//  MoonCast: Xbox super resolution (FsrGlDrawer on Android): WebRTC's hardware-decoded frames go through FSR when
//  they're clearly smaller than the screen, everything else to WebRTC's own Metal view.
//

import WebRTC

final class MCFsrRtcRenderer: NSObject, RTCVideoRenderer {
    private let fsr: MCFsrView
    private let plain: RTCMTLVideoView
    private var usingFsr: Bool?

    init(fsr: MCFsrView, plain: RTCMTLVideoView) {
        self.fsr = fsr
        self.plain = plain
    }

    func setSize(_ size: CGSize) {
        plain.setSize(size)
        if size.height > 0 { fsr.aspect = size.width / size.height }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else { return }
        let worth = MCFsr.worthIt(videoHeight: Int(frame.height), screenHeight: MCFsr.screenPixelHeight)
        if worth, let cv = frame.buffer as? RTCCVPixelBuffer {
            show(fsr: true)
            fsr.display(cv.pixelBuffer)
        } else {
            show(fsr: false)
            plain.renderFrame(frame)
        }
    }

    private func show(fsr on: Bool) {
        guard usingFsr != on else { return }
        usingFsr = on
        DispatchQueue.main.async { self.fsr.isHidden = !on; self.plain.isHidden = on }
    }
}
