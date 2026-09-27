import AVFoundation
import CoreImage
import Foundation

final class CameraPPGRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CardioMag.CameraPPG")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var recent: [(Double, Double)] = []
    private var lastBeat = -Double.infinity
    var onPoint: ((TimeInterval, Double, Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    func requestAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                self?.onStatus?("Camera denied — use manual beat markers or import timestamps.")
                return
            }
            self?.queue.async { self?.configureAndStart() }
        }
    }

    private func configureAndStart() {
        guard !session.isRunning else { return }
        recent.removeAll()
        lastBeat = -Double.infinity
        // Configured by an earlier recording: stop() leaves the input attached, and adding it again
        // failed, so every recording after the first reported the camera unavailable.
        if !session.inputs.isEmpty {
            setTorch(on: true)
            session.startRunning()
            onStatus?("Camera PPG active")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .low
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
        else {
            session.commitConfiguration()
            onStatus?("Rear camera unavailable — PPG disabled.")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        setTorch(on: true)
        session.startRunning()
        onStatus?("Camera PPG active")
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
            self?.setTorch(on: false)
        }
    }

    private func setTorch(on: Bool) {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), camera.hasTorch,
            (try? camera.lockForConfiguration()) != nil
        else { return }
        if on { try? camera.setTorchModeOn(level: 0.25) } else { camera.torchMode = .off }
        camera.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frame times converted exactly to the host clock, the one CoreMotion timestamps use. Estimating
        // the offset from the first frame's arrival built that frame's delivery latency into every
        // beat time, a bias that differed from one recording to the next.
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMSyncConvertTime(
            presentation, from: session.synchronizationClock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock()
        ).seconds
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        let vector = CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: vector]),
            let out = filter.outputImage
        else { return }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        let red = Double(pixel[0]) / 255
        recent.append((timestamp, red))
        recent.removeAll { timestamp - $0.0 > 8 }
        let detrended = normalized(red)
        let beat = detectBeat(time: timestamp, value: detrended)
        onPoint?(timestamp, detrended, beat)
    }

    private func normalized(_ latest: Double) -> Double {
        guard recent.count > 8 else { return 0 }
        let values = recent.map(\.1)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (latest - mean) / max(sqrt(variance), 0.001)
    }

    private func detectBeat(time: Double, value: Double) -> Bool {
        guard recent.count > 12, time - lastBeat > 0.35 else { return false }
        let raw = recent.suffix(10).map(\.1)
        let mean = raw.reduce(0, +) / Double(raw.count)
        let rising = raw.last! > mean && raw.last! > raw[raw.count - 2]
        if value > 0.8 && rising {
            lastBeat = time
            return true
        }
        return false
    }
}
