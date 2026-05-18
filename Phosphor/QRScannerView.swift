import SwiftUI
import AVFoundation

/// Minimal QR-code scanner. Calls `onScan` with the decoded string once a
/// successful read occurs; the caller is responsible for dismissing.
struct QRScannerView: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(onScan: { code in
                onScan(code)
            }, permissionDenied: $permissionDenied)
                .ignoresSafeArea()

            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
                Text("Align the QR code inside the frame")
                    .font(Typography.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, Spacing.md)
                Spacer()
            }

            if permissionDenied {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.white)
                    Text("Camera access denied")
                        .font(Typography.headline)
                        .foregroundStyle(.white)
                    Text("Enable camera access in Settings to scan QR codes.")
                        .font(Typography.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Cancel") { dismiss() }
                .padding(Spacing.lg)
                .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }
}

private struct CameraPreview: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    @Binding var permissionDenied: Bool

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        controller.onPermissionDenied = { permissionDenied = true }
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?
    private let session = AVCaptureSession()
    private var didReport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.configure()
                } else {
                    self?.onPermissionDenied?()
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
            }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }
            .forEach { $0.frame = view.bounds }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didReport,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty
        else { return }
        didReport = true
        onScan?(value)
    }
}
