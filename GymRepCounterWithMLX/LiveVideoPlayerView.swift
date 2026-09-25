// LiveVideoPlayerView.swift
// Shows the decoded gallery-live frames (CGImage) with the body-pose skeleton overlaid,
// aspect-fit. Mapping mirrors LiveCameraView but the background is an image layer instead of
// a camera preview layer.

import SwiftUI

struct LiveVideoPlayerView: UIViewRepresentable {
    let image: CGImage?
    let pose: PoseFrame?
    let orientedSize: CGSize

    func makeUIView(context: Context) -> LiveVideoUIView { LiveVideoUIView() }

    func updateUIView(_ uiView: LiveVideoUIView, context: Context) {
        uiView.orientedSize = orientedSize
        uiView.image = image
        uiView.pose = pose
    }
}

final class LiveVideoUIView: UIView {

    private static let bones: [(String, String)] = [
        ("left_shoulder", "right_shoulder"), ("left_hip", "right_hip"),
        ("left_shoulder", "left_hip"), ("right_shoulder", "right_hip"),
        ("left_shoulder", "left_elbow"), ("left_elbow", "left_wrist"),
        ("right_shoulder", "right_elbow"), ("right_elbow", "right_wrist"),
        ("left_hip", "left_knee"), ("left_knee", "left_ankle"),
        ("right_hip", "right_knee"), ("right_knee", "right_ankle"),
        ("nose", "left_shoulder"), ("nose", "right_shoulder"),
    ]

    private let imageLayer = CALayer()
    private let boneLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()

    var orientedSize: CGSize = .zero
    var image: CGImage? { didSet { imageLayer.contents = image; render() } }
    var pose: PoseFrame? { didSet { render() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageLayer.contentsGravity = .resizeAspect
        layer.addSublayer(imageLayer)
        boneLayer.strokeColor = UIColor.systemGreen.cgColor
        boneLayer.lineWidth = 3
        boneLayer.lineCap = .round
        boneLayer.fillColor = UIColor.clear.cgColor
        jointLayer.fillColor = UIColor.systemYellow.cgColor
        jointLayer.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(boneLayer)
        layer.addSublayer(jointLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        boneLayer.frame = bounds
        jointLayer.frame = bounds
        CATransaction.commit()
        render()
    }

    /// Aspect-fit rect for the image inside the view (matches `.resizeAspect`).
    private func fittedRect() -> CGRect? {
        guard orientedSize.width > 0, orientedSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / orientedSize.width, bounds.height / orientedSize.height)
        let size = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func render() {
        guard let pose, !pose.joints.isEmpty, let rect = fittedRect() else { clear(); return }

        func point(_ name: String) -> CGPoint? {
            guard let j = pose.joints[name] else { return nil }
            return CGPoint(x: rect.minX + j.x * rect.width, y: rect.minY + j.y * rect.height)
        }

        let bonePath = CGMutablePath()
        for (a, b) in Self.bones {
            guard let pa = point(a), let pb = point(b) else { continue }
            bonePath.move(to: pa)
            bonePath.addLine(to: pb)
        }

        let jointPath = CGMutablePath()
        let r: CGFloat = 5
        for name in pose.joints.keys {
            guard let p = point(name) else { continue }
            jointPath.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boneLayer.path = bonePath
        jointLayer.path = jointPath
        CATransaction.commit()
    }

    private func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boneLayer.path = nil
        jointLayer.path = nil
        CATransaction.commit()
    }
}
