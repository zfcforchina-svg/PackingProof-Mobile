import AVFoundation
import Flutter
import Vision
import UIKit

/// iOS equivalent of Android's ContinuousSegmentCamera.
/// Uses AVFoundation capture session + AVAssetWriter for hardware-accelerated
/// H.264 video encoding, Vision for barcode scanning, and Flutter texture
/// registry for zero-copy preview frames.
class ContinuousCameraPlugin: NSObject, FlutterTexture {
    // MARK: - Channel & lifecycle

    private let channel: FlutterMethodChannel
    private let registry: FlutterTextureRegistry
    private let messenger: FlutterBinaryMessenger

    // MARK: - Capture pipeline

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "packingproof.camera.session")
    private let videoQueue = DispatchQueue(label: "packingproof.camera.video")
    private let audioQueue = DispatchQueue(label: "packingproof.camera.audio")
    private let analysisQueue = DispatchQueue(label: "packingproof.camera.analysis", qos: .userInitiated)

    private var cameraDevice: AVCaptureDevice?
    private var audioDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var textureId: Int64 = 0

    // MARK: - Recording

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingRequested = false
    private var recordingActive = false
    private var currentPath: String?
    private var segmentStartedAt: Date?
    private var lastVideoPts = CMTime.zero
    private var videoFrameCount: Int64 = 0
    private var audioStarted = false

    // MARK: - Pending operations

    private var startResult: FlutterResult?
    private var splitResult: FlutterResult?
    private var stopResult: FlutterResult?
    private var initializeResult: FlutterResult?
    private var pendingStartPath: String?
    private var pendingSplitPath: String?

    // MARK: - Barcode scanning

    private var barcodeRequest: VNRecognizeTextRequest?
    private var pairingScanEnabled = false
    private var workScanEnabled = false
    private var lastAnalysisTime = Date.distantPast
    private let analysisInterval: TimeInterval = 0.25

    // MARK: - State

    private var initialized = false
    private var disposed = false
    private var selectedLensPosition: AVCaptureDevice.Position = .back
    private var canSwitchCamera = false
    private var torchAvailable = false
    private var torchEnabled = false
    private var previewActive = true
    private var latestPixelBuffer: CVPixelBuffer?

    // Hard-coded video settings (matches Android)
    private let videoWidth = 1920
    private let videoHeight = 1080
    private let videoFps: Int32 = 30
    private let videoBitRate = 7_000_000

    // MARK: - Flutter texture support

    private var textureFrameAvailable = false
    private let textureLock = NSLock()

    // MARK: - Init

    init(
        registry: FlutterTextureRegistry,
        messenger: FlutterBinaryMessenger
    ) {
        self.registry = registry
        self.messenger = messenger
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/continuous_camera",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    // MARK: - Method call handler

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            initialize(result)
        case "startWork":
            guard let path = call.arguments as? String, !path.isEmpty else {
                result(FlutterError(code: "invalid_path", message: "录像文件路径不能为空", details: nil))
                return
            }
            startWork(path: path, result: result)
        case "split":
            guard let path = call.arguments as? String, !path.isEmpty else {
                result(FlutterError(code: "invalid_path", message: "下一段录像路径不能为空", details: nil))
                return
            }
            split(path: path, result: result)
        case "stopWork":
            stopWork(result)
        case "setPairingScanEnabled":
            pairingScanEnabled = (call.arguments as? Bool) == true
            result(nil)
        case "setWorkScanEnabled":
            workScanEnabled = (call.arguments as? Bool) == true
            if !workScanEnabled { lastAnalysisTime = .distantPast }
            result(nil)
        case "setPreviewActive":
            previewActive = (call.arguments as? Bool) == true
            result(nil)
        case "setTorchEnabled":
            setTorch(enabled: (call.arguments as? Bool) == true, result: result)
        case "switchCamera":
            guard canSwitchNow() else {
                result(FlutterError(code: "camera_busy", message: "当前状态不能切换摄像头", details: nil))
                return
            }
            switchCamera(result)
        case "dispose":
            disposeCamera()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Initialize

    private func initialize(_ result: @escaping FlutterResult) {
        guard !disposed else {
            result(FlutterError(code: "disposed", message: "摄像头已经关闭", details: nil))
            return
        }
        guard !initialized else {
            result(initializationMap())
            return
        }
        guard initializeResult == nil else {
            result(FlutterError(code: "initializing", message: "摄像头正在初始化", details: nil))
            return
        }
        initializeResult = result

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            sessionQueue.async { self.startCaptureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.startCaptureSession() }
                } else {
                    self.failInitialization("permission_denied", "需要摄像头权限才能工作")
                }
            }
        default:
            failInitialization("permission_denied", "需要摄像头权限才能工作")
        }
    }

    private func startCaptureSession() {
        do {
            try configureSession()
            textureId = registry.register(self)
            initialized = true
            captureSession.startRunning()
            let map = initializationMap()
            DispatchQueue.main.async {
                let r = self.initializeResult
                self.initializeResult = nil
                r?(map)
            }
        } catch {
            failInitialization("camera_init", error.localizedDescription)
        }
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        // Select camera
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: selectedLensPosition
        )
        guard let camera = discovery.devices.first else {
            throw NSError(domain: "camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有检测到可用摄像头"])
        }
        cameraDevice = camera
        canSwitchCamera = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: selectedLensPosition == .back ? .front : .back
        ).devices.first != nil
        torchAvailable = camera.hasTorch && camera.isTorchAvailable

        // Add video input
        let videoIn = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(videoIn) else {
            throw NSError(domain: "camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法添加摄像头输入"])
        }
        captureSession.addInput(videoIn)
        videoInput = videoIn

        // Add audio input
        if let audio = AVCaptureDevice.default(for: .audio) {
            audioDevice = audio
            let audioIn = try AVCaptureDeviceInput(device: audio)
            if captureSession.canAddInput(audioIn) {
                captureSession.addInput(audioIn)
                audioInput = audioIn
            }
        }

        // Video output (for preview frames + encoding + barcode)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw NSError(domain: "camera", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法添加视频输出"])
        }
        captureSession.addOutput(videoOutput)

        // Audio output
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        // Configure camera for 30fps
        try camera.lockForConfiguration()
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        camera.unlockForConfiguration()

        captureSession.commitConfiguration()
    }

    // MARK: - Recording

    private func startWork(path: String, result: @escaping FlutterResult) {
        guard initialized else {
            result(FlutterError(code: "camera_not_ready", message: "摄像头尚未准备完成", details: nil))
            return
        }
        guard !recordingRequested, !recordingActive, startResult == nil else {
            result(FlutterError(code: "already_recording", message: "录像已经开始", details: nil))
            return
        }
        ensureParentDir(path)

        recordingRequested = true
        pendingStartPath = path
        startResult = result
        videoFrameCount = 0
        audioStarted = false

        // Start AVAssetWriter on video queue when first frame arrives
    }

    private func split(path: String, result: @escaping FlutterResult) {
        guard recordingActive else {
            result(FlutterError(code: "not_recording", message: "当前没有正在录制的视频", details: nil))
            return
        }
        guard splitResult == nil else {
            result(FlutterError(code: "split_pending", message: "上一段录像正在保存", details: nil))
            return
        }
        pendingSplitPath = path
        splitResult = result
        // Actual rotation happens on next video frame
    }

    private func stopWork(_ result: @escaping FlutterResult) {
        guard recordingRequested || recordingActive else {
            result(FlutterError(code: "not_recording", message: "当前没有正在录制的视频", details: nil))
            return
        }
        guard stopResult == nil else {
            result(FlutterError(code: "stop_pending", message: "录像正在保存", details: nil))
            return
        }
        stopResult = result
        recordingRequested = false
        recordingActive = false
        finishRecording()
    }

    private func canSwitchNow() -> Bool {
        return initialized && canSwitchCamera &&
            !recordingRequested && !recordingActive &&
            startResult == nil && stopResult == nil && splitResult == nil &&
            !pairingScanEnabled && !workScanEnabled
    }

    // MARK: - Torch

    private func setTorch(enabled: Bool, result: @escaping FlutterResult) {
        guard initialized, let device = cameraDevice else {
            result(FlutterError(code: "camera_not_ready", message: "摄像头尚未准备完成", details: nil))
            return
        }
        guard torchAvailable else {
            result(FlutterError(code: "flash_unavailable", message: "当前摄像头不支持闪光灯", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            torchEnabled = enabled
            result(enabled)
        } catch {
            result(FlutterError(code: "torch_error", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Camera switch

    private func switchCamera(_ result: @escaping FlutterResult) {
        selectedLensPosition = selectedLensPosition == .back ? .front : .back
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        if let oldInput = videoInput {
            captureSession.removeInput(oldInput)
        }
        videoInput = nil
        cameraDevice = nil
        do {
            try configureSession()
            captureSession.commitConfiguration()
            captureSession.startRunning()
            result(initializationMap())
        } catch {
            captureSession.commitConfiguration()
            captureSession.startRunning()
            result(FlutterError(code: "switch_failed", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - AVAssetWriter management

    private func startAssetWriter(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mp4)

            // Video input
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoExpectedSourceFrameRateKey: videoFps
                ]
            ]
            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoIn.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoIn,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: videoWidth,
                    kCVPixelBufferHeightKey as String: videoHeight
                ]
            )

            // Audio input
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000
            ]
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioIn.expectsMediaDataInRealTime = true

            if writer.canAdd(videoIn) { writer.add(videoIn) }
            if writer.canAdd(audioIn) { writer.add(audioIn) }

            writer.startWriting()
            assetWriter = writer
            videoWriterInput = videoIn
            audioWriterInput = audioIn
            pixelBufferAdaptor = adaptor
            currentPath = path
            segmentStartedAt = Date()
            lastVideoPts = CMTime.zero
        } catch {
            failPendingStart("muxer_start", "录像文件创建失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Preview texture (FlutterTexture)

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        textureLock.lock()
        defer { textureLock.unlock() }
        guard let buffer = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    // MARK: - Helpers

    private func initializationMap() -> [String: Any] {
        return [
            "textureId": textureId,
            "previewWidth": videoWidth,
            "previewHeight": videoHeight,
            "sensorOrientation": 90,
            "lensDirection": selectedLensPosition == .front ? "front" : "back",
            "canSwitchCamera": canSwitchCamera,
            "fps": videoFps,
            "videoMime": "video/avc",
            "flashAvailable": torchAvailable
        ]
    }

    private func ensureParentDir(_ path: String) {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func failInitialization(_ code: String, _ message: String) {
        let r = initializeResult
        initializeResult = nil
        initialized = false
        DispatchQueue.main.async {
            r?(FlutterError(code: code, message: message, details: nil))
        }
    }

    private func failPendingStart(_ code: String, _ message: String) {
        let r = startResult
        startResult = nil
        pendingStartPath = nil
        recordingRequested = false
        DispatchQueue.main.async {
            r?(FlutterError(code: code, message: message, details: nil))
        }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async {
            self.channel.invokeMethod("nativeError", arguments: message)
        }
    }

    private func emitBarcodeFrame(_ candidates: [[String: Any]]) {
        DispatchQueue.main.async {
            self.channel.invokeMethod("barcodeFrame", arguments: candidates)
        }
    }

    private func finishRecording() {
        guard let writer = assetWriter, writer.status == .writing else {
            completeStop(nil)
            return
        }
        let path = currentPath
        let startedAt = segmentStartedAt
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            self?.completeStop(path, startedAt: startedAt)
        }
    }

    private func completeStop(_ path: String?, startedAt: Date? = nil) {
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        currentPath = nil
        segmentStartedAt = nil

        let r = stopResult
        stopResult = nil
        DispatchQueue.main.async {
            if let path = path, let startedAt = startedAt {
                r?([
                    "path": path,
                    "startedAtMs": Int64(startedAt.timeIntervalSince1970 * 1000),
                    "endedAtMs": Int64(Date().timeIntervalSince1970 * 1000)
                ])
            } else {
                r?(FlutterError(code: "empty_recording", message: "没有生成有效录像", details: nil))
            }
        }
    }

    private func rotateSegment(_ completedPath: String, nextPath: String, boundaryAt: Date) {
        guard let writer = assetWriter else { return }

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        let completedStartedAt = segmentStartedAt

        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.startAssetWriter(path: nextPath)
            let r = self.splitResult
            self.splitResult = nil
            self.pendingSplitPath = nil
            DispatchQueue.main.async {
                r?([
                    "completedPath": completedPath,
                    "nextPath": nextPath,
                    "completedStartedAtMs": Int64((completedStartedAt?.timeIntervalSince1970 ?? 0) * 1000),
                    "boundaryAtMs": Int64(boundaryAt.timeIntervalSince1970 * 1000)
                ])
            }
        }
    }

    func disposeCamera() {
        disposed = true
        initialized = false

        initializeResult?(FlutterError(code: "disposed", message: "摄像头初始化已取消", details: nil))
        startResult?(FlutterError(code: "disposed", message: "录像启动已取消", details: nil))
        splitResult?(FlutterError(code: "disposed", message: "录像分段已取消", details: nil))
        stopResult?(FlutterError(code: "disposed", message: "录像保存已取消", details: nil))

        initializeResult = nil
        startResult = nil
        splitResult = nil
        stopResult = nil

        recordingRequested = false
        recordingActive = false

        sessionQueue.async {
            self.captureSession.stopRunning()
        }
        registry.unregisterTexture(textureId)
        channel.setMethodCallHandler(nil)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & Audio

extension ContinuousCameraPlugin: AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output == videoOutput {
            handleVideoSample(sampleBuffer, connection: connection)
        } else if output == audioOutput {
            handleAudioSample(sampleBuffer)
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Update preview texture
        textureLock.lock()
        latestPixelBuffer = pixelBuffer
        textureLock.unlock()
        registry.textureFrameAvailable(textureId)

        // Barcode analysis
        let now = Date()
        let shouldAnalyze = (recordingActive || recordingRequested || workScanEnabled || pairingScanEnabled) &&
            now.timeIntervalSince(lastAnalysisTime) >= analysisInterval
        if shouldAnalyze {
            lastAnalysisTime = now
            detectBarcode(pixelBuffer)
        }

        // Recording start / split logic
        if recordingRequested, let path = pendingStartPath, startResult != nil, assetWriter == nil {
            startAssetWriter(path: path)
        }

        guard let writer = assetWriter, writer.status == .writing || writer.status == .unknown else { return }

        if writer.status == .unknown, !recordingRequested, !recordingActive {
            return
        }

        // Split
        if splitResult != nil, let splitPath = pendingSplitPath, let completedPath = currentPath {
            rotateSegment(completedPath, nextPath: splitPath, boundaryAt: Date())
            return
        }

        // Start session on first frame
        if writer.status == .unknown {
            writer.startSession(atSourceTime: pts)
            segmentStartedAt = Date()
            recordingActive = true
            let r = startResult
            startResult = nil
            pendingStartPath = nil
            DispatchQueue.main.async {
                r?([
                    "path": self.currentPath ?? "",
                    "startedAtMs": Int64(Date().timeIntervalSince1970 * 1000)
                ])
            }
        }

        // Write video
        guard writer.status == .writing, let videoIn = videoWriterInput, videoIn.isReadyForMoreMediaData else { return }
        guard let adaptor = pixelBufferAdaptor else { return }

        // Resize if needed
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

        if srcWidth == videoWidth && srcHeight == videoHeight {
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        } else if let resized = resizePixelBuffer(pixelBuffer, to: CGSize(width: videoWidth, height: videoHeight)) {
            adaptor.append(resized, withPresentationTime: pts)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter, writer.status == .writing,
              let audioIn = audioWriterInput, audioIn.isReadyForMoreMediaData else { return }
        audioIn.append(sampleBuffer)
    }

    // MARK: - Barcode detection

    private func detectBarcode(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard let self = self else { return }
            guard let results = request.results as? [VNBarcodeObservation] else {
                self.emitBarcodeFrame([])
                return
            }
            let candidates = results.compactMap { obs -> [String: Any]? in
                guard let value = obs.payloadStringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                    return nil
                }
                let area = Int(obs.boundingBox.width * obs.boundingBox.height * 1_000_000)
                return ["value": value, "area": area]
            }
            self.emitBarcodeFrame(candidates)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Pixel buffer resize

    private func resizePixelBuffer(_ source: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let dest = output else { return nil }

        let ciContext = CIContext()
        let ciImage = CIImage(cvPixelBuffer: source)
        let scaleX = size.width / CGFloat(CVPixelBufferGetWidth(source))
        let scaleY = size.height / CGFloat(CVPixelBufferGetHeight(source))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: dest)
        return dest
    }
}
