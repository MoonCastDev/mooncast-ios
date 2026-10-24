//
//  MCStatsPill.swift
//  MoonCast: Settings → Picture → Stats while playing, the same card for PC, PS5 and Xbox: a frosted capsule in the
//  top-left corner with a health dot and the live numbers as chips (big value, small label). Updated once a second;
//  it only lays out again when a value changes.
//

import UIKit

@objc(MCStatsPill)
final class MCStatsPill: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let row = UIStackView()
    private let dot = UIView()
    private var shown: [String] = []

    /// Adds a card to [view], top left inside its safe area. Hidden until the first numbers.
    @objc static func attach(to view: UIView) -> MCStatsPill {
        let p = MCStatsPill()
        p.isHidden = true
        p.isUserInteractionEnabled = false
        p.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(p)
        NSLayoutConstraint.activate([
            p.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            p.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
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
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 4.5
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -8),
            dot.widthAnchor.constraint(equalToConstant: 9), dot.heightAnchor.constraint(equalToConstant: 9),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.layer.cornerRadius = bounds.height / 2
    }

    /// The live numbers; a negative value is "not known yet" and its chip is left out. [lost] is a percentage, or a
    /// count of lost frames when [lostIsCount].
    @objc func show(fps: Double, rttMs: Double, mbps: Double, lost: Double, lostIsCount: Bool, hostMs: Double, codec: String) {
        guard fps >= 0 else { isHidden = true; return }
        var chips: [(String, String)] = [(String(format: "%.0f", fps), "FPS")]
        if rttMs >= 0 { chips.append((String(format: "%.0f ms", rttMs), "DELAY")) }
        if mbps >= 0 { chips.append((String(format: mbps < 10 ? "%.1f" : "%.0f", mbps), "MBPS")) }
        if lost >= 0 { chips.append((lostIsCount ? String(format: "%.0f", lost) : String(format: "%.1f%%", lost), "LOST")) }
        if hostMs >= 0 { chips.append((String(format: "%.1f ms", hostMs), "HOST")) }
        if !codec.isEmpty { chips.append((MCQuickModel.shortCodec(codec), "CODEC")) }
        // green: a good link; amber: noticeable; red: struggling
        let lossPct = lostIsCount ? 0 : max(0, lost)
        let health: UIColor = (rttMs < 0 || rttMs <= 30) && lossPct < 1 ? UIColor(red: 0.18, green: 0.75, blue: 0.35, alpha: 1)
            : (rttMs < 0 || rttMs <= 60) && lossPct < 5 ? UIColor(red: 0.95, green: 0.71, blue: 0.36, alpha: 1)
            : UIColor(red: 0.91, green: 0.38, blue: 0.35, alpha: 1)
        dot.backgroundColor = health
        isHidden = false
        let flat = chips.map { $0.0 + "|" + $0.1 }
        guard flat != shown else { return }
        shown = flat
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        row.addArrangedSubview(dot)
        for (v, l) in chips {
            let value = UILabel()
            value.text = v
            value.textColor = .white
            value.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .heavy)
            let label = UILabel()
            label.text = l
            label.textColor = UIColor(white: 1, alpha: 0.55)
            label.font = .systemFont(ofSize: 9.5, weight: .bold)
            let col = UIStackView(arrangedSubviews: [value, label])
            col.axis = .vertical
            col.alignment = .leading
            col.spacing = 0
            row.addArrangedSubview(col)
        }
    }

    /// From the Quick menu's numbers (mcStats): fps, rtt, mbps, loss (%) or lostFrames, host, codec.
    @objc func show(stats d: [AnyHashable: Any]) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        let lostFrames = num("lostFrames")
        show(fps: num("fps") ?? -1, rttMs: num("rtt") ?? -1, mbps: num("mbps") ?? -1,
             lost: lostFrames ?? num("loss") ?? -1, lostIsCount: lostFrames != nil, hostMs: num("host") ?? -1,
             codec: d["codec"] as? String ?? "")
    }
}
