@preconcurrency import AVFoundation

/// A camera source. Frames arrive as 4:2:0 YUV on the capture queue; the most
/// recent one is kept for screenshot mode.
nonisolated final class CameraCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let pixelWidth: Int
    let pixelHeight: Int

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(deviceID: String, onStop: @escaping @Sendable (Error) -> Void) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw TempusError.sourceUnavailable("Camera")
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TempusError.sourceUnavailable(device.localizedName) }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { throw TempusError.sourceUnavailable(device.localizedName) }
        session.addOutput(output)
        session.commitConfiguration()

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        pixelWidth = Int(dimensions.width)
        pixelHeight = Int(dimensions.height)
        super.init()
        output.setSampleBufferDelegate(self, queue: CaptureQueue.queue)

        let label = device.localizedName
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
            onStop(TempusError.sourceUnavailable(label))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            onStop((note.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? TempusError.sourceUnavailable(label))
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(onFrame: (@Sendable (CVPixelBuffer) -> Void)? = nil) async {
        lock.withLock { self.onFrame = onFrame }
        let session = Unchecked(session)
        // startRunning blocks until the camera is up, so keep it off the main thread.
        await CaptureQueue.run { session.value.startRunning() }
    }

    func stop() async {
        lock.withLock { onFrame = nil }
        let session = Unchecked(session)
        await CaptureQueue.run { session.value.stopRunning() }
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.withLock { latest }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let handler = lock.withLock {
            latest = pixelBuffer
            return onFrame
        }
        handler?(pixelBuffer)
    }
}
