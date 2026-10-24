//
//  MCStatsPill.swift
//  MoonCast: Settings → Picture → Stats while playing, the same overlay for PC, PS5 and Xbox, at two levels:
//  Lite, a small capsule centred at the top (health dot, fps, delay), and Detailed, a frosted panel in the top-left
//  corner with every number the player has. Updated once a second; it only lays out again when a value changes.
//

import UIKit

/// Stats while playing: "off", "lite" or "detailed", one choice for PC, PS5 and Xbox. The Quick menu's Streaming
/// status steps through them. Before the levels it was a switch: on counts as Detailed.
@objc(MCStatsLevel)
final class MCStatsLevel: NSObject {
    private static let key = "mc_stats_level"

    @objc static var current: String {
        if let v = UserDefaults.standard.string(forKey: key), ["off", "lite", "detailed"].contains(v) { return v }
        return MCSettings().load().stats ? "detailed" : "off"
    }

    @objc static func set(_ level: String) {
        UserDefaults.standard.set(level, forKey: key)
        // Moonlight's own switch starts the PC player's timer
        MCSettings().save { $0.stats = level != "off" }
    }

    /// Off → Lite → Detailed → Off; returns the new level.
    @objc @discardableResult static func cycle() -> String {
        let next = ["off": "lite", "lite": "detailed"][current] ?? "off"
        set(next)
        return next
    }

    @objc static func label(_ level: String) -> String { ["lite": "Lite", "detailed": "Detailed"][level] ?? "Off" }
}

@objc(MCStatsPill)
final class MCStatsPill: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let stack = UIStackView()
    private var shown: [String] = []
    private var leadC: NSLayoutConstraint?
    private var centreC: NSLayoutConstraint?

    /// "lite" (centred at the top) or "detailed" (top left).
    @objc var level = "detailed" {
        didSet {
            guard level != oldValue else { return }
            leadC?.isActive = level != "lite"
            centreC?.isActive = level == "lite"
            shown = []
            setNeedsLayout()
        }
    }

    /// Adds an overlay to [view] inside its safe area, at the level Settings say. Hidden until the first numbers.
    @objc static func attach(to view: UIView) -> MCStatsPill {
        let p = MCStatsPill()
        p.isHidden = true
        p.isUserInteractionEnabled = false
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        let g = view.safeAreaLayoutGuide
        p.leadC = p.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 14)
        p.centreC = p.centerXAnchor.constraint(equalTo: g.centerXAnchor)
        NSLayoutConstraint.activate([p.topAnchor.constraint(equalTo: g.topAnchor, constant: 12)])
        p.level = MCStatsLevel.current == "lite" ? "lite" : "detailed"
        p.leadC?.isActive = p.level != "lite"
        p.centreC?.isActive = p.level == "lite"
        return p
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.clipsToBounds = true
        blur.layer.cornerCurve = .continuous
        blur.layer.borderWidth = 1
        blur.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
        addSubview(blur)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -7),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.layer.cornerRadius = level == "lite" ? bounds.height / 2 : 16
    }

    private static func dot(_ c: UIColor) -> UIView {
        let d = UIView()
        d.backgroundColor = c
        d.layer.cornerRadius = 4.5
        d.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([d.widthAnchor.constraint(equalToConstant: 9), d.heightAnchor.constraint(equalToConstant: 9)])
        return d
    }

    private static func text(_ s: String, _ size: CGFloat, _ weight: UIFont.Weight, _ alpha: CGFloat = 1) -> UILabel {
        let l = UILabel()
        l.text = s
        l.textColor = UIColor(white: 1, alpha: alpha)
        l.font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return l
    }

    /// The player's numbers (the Quick menu's mcStats): fps, rtt, rttVar, mbps, loss (%) or lostFrames, host,
    /// hostMin, hostMax, decode, codec, size ("1920x1080"), targetFps. Missing or negative values are left out.
    @objc func show(stats d: [AnyHashable: Any]) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber).map { $0.doubleValue }.flatMap { $0 >= 0 ? $0 : nil } }
        guard let fps = num("fps") else { isHidden = true; return }
        let rtt = num("rtt"), lostFrames = num("lostFrames"), loss = num("loss")
        let lossPct = lostFrames == nil ? (loss ?? 0) : 0
        // green: a good link; amber: noticeable; red: struggling
        let health: UIColor = (rtt ?? 0) <= 30 && lossPct < 1 ? UIColor(red: 0.18, green: 0.75, blue: 0.35, alpha: 1)
            : (rtt ?? 0) <= 60 && lossPct < 5 ? UIColor(red: 0.95, green: 0.71, blue: 0.36, alpha: 1)
            : UIColor(red: 0.91, green: 0.38, blue: 0.35, alpha: 1)
        let fpsText = String(format: "%.0f", fps) + (num("targetFps").map { String(format: " / %.0f", $0) } ?? "")
        var rows: [(String, String)] = []
        if level == "lite" {
            rows = [("fps", String(format: "%.0f fps", fps))]
            if let r = rtt { rows.append(("rtt", String(format: "%.0f ms", r))) }
        } else {
            if let s = d["size"] as? String, !s.isEmpty { rows.append(("Video", s.replacingOccurrences(of: "x", with: " × "))) }
            rows.append(("Frame rate", fpsText + " fps"))
            if let c = d["codec"] as? String, !c.isEmpty { rows.append(("Codec", c)) }
            if let m = num("mbps") { rows.append(("Bitrate", String(format: m < 10 ? "%.1f Mbps" : "%.0f Mbps", m))) }
            if let r = rtt { rows.append(("Network delay", String(format: "%.0f ms", r) + (num("rttVar").map { String(format: " ± %.0f", $0) } ?? ""))) }
            if let dec = num("decode") { rows.append(("Decode", String(format: "%.1f ms", dec))) }
            if let h = num("host") {
                rows.append(("Host processing", num("hostMin").flatMap { mn in num("hostMax").map { mx in
                    String(format: "%.1f / %.1f / %.1f ms", mn, h, mx) } } ?? String(format: "%.1f ms", h)))
            }
            if let lf = lostFrames { rows.append(("Lost", String(format: "%.0f frames", lf))) }
            else if let l = loss { rows.append(("Network loss", String(format: "%.2f%%", l))) }
        }
        isHidden = false
        let flat = [level, "\(health)"] + rows.map { $0.0 + "|" + $0.1 }
        guard flat != shown else { return }
        shown = flat
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if level == "lite" {
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 12
            stack.addArrangedSubview(Self.dot(health))
            rows.forEach { stack.addArrangedSubview(Self.text($0.1, 15, .heavy)) }
        } else {
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 3
            let head = UIStackView(arrangedSubviews: [Self.dot(health), Self.text("PERFORMANCE", 10, .heavy, 0.6)])
            head.spacing = 8
            head.alignment = .center
            stack.addArrangedSubview(head)
            stack.setCustomSpacing(6, after: head)
            for (k, v) in rows {
                let key = Self.text(k, 12, .semibold, 0.6)
                key.setContentHuggingPriority(.required, for: .horizontal)
                key.widthAnchor.constraint(equalToConstant: 118).isActive = true
                let line = UIStackView(arrangedSubviews: [key, Self.text(v, 13.5, .bold)])
                line.spacing = 10
                stack.addArrangedSubview(line)
            }
        }
    }
}
