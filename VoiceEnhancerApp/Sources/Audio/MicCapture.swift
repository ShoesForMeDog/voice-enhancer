import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// Converts the hardware-native tap buffers to the fixed DSP/ring format.
/// The converter is created from the first buffer's actual format rather than
/// from the input node's pre-start format. Bluetooth devices can advertise
/// 48 kHz while idle and switch to 24 kHz only when capture begins.
private final class NativeInputConverter {
    private let outputFormat: AVAudioFormat
    private let outputBuffer: AVAudioPCMBuffer
    private var converter: AVAudioConverter?

    init?(outputFormat: AVAudioFormat, maximumOutputFrames: AVAudioFrameCount) {
        self.outputFormat = outputFormat
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: maximumOutputFrames
        ) else { return nil }
        self.outputBuffer = outputBuffer
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if formatsMatch(inputBuffer.format, outputFormat) {
            return inputBuffer
        }

        if converter == nil || !formatsMatch(converter!.inputFormat, inputBuffer.format) {
            guard let newConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
                return nil
            }
            // Voice Enhancer intentionally uses the first channel of a
            // multichannel microphone rather than mixing channels together.
            newConverter.channelMap = [0]
            newConverter.primeMethod = .none
            converter = newConverter
        }

        guard let converter else { return nil }
        outputBuffer.frameLength = 0
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

/// Microphone capture + routing using `AVAudioEngine`.
///
/// Responsibilities:
///   * Set up an input node tap on a user-selected input device.
///   * For each captured buffer, call into the ``AudioEngineBridge`` to
///     process audio in place.
///   * Publish the processed audio into the shared-memory ring so the
///     virtual HAL driver (running inside coreaudiod) can serve it as a
///     microphone to any recording app.
///
/// Design notes:
///   * Mono processing. We take the first channel of the input and treat it
///     as the voice signal. Stereo mics (rare for voice work) get the left
///     channel only. This keeps the DSP path simple and matches how meeting
///     apps treat microphones anyway.
///   * Buffer size is 512 frames at 48 kHz (~10.7 ms). Good balance of
///     latency vs. CPU efficiency.
///   * Format conversion is handled by AVAudioEngine itself — we install
///     the tap with the ring's target format (48 kHz mono float32) and the
///     engine inserts an RT-safe converter in its audio graph when the
///     input device's native format differs.
final class MicCapture {
    /// AVAudioEngine can hand us much larger blocks than the requested tap
    /// buffer size during route changes and on some built-in devices. Keep
    /// ample headroom so those blocks don't get dropped before DSP.
    private static let maxProcessingFrames = 65_536

    private let logger = Logger(subsystem: "tech.aheadly.voice-enhancer", category: "MicCapture")
    private let engineBridge: AudioEngineBridge
    private let ringBridge: RingBufferBridge
    /// A fresh engine is created for every capture session. Reusing an engine
    /// across route changes can leave AVFAudio's private tap state attached to
    /// the input node even after `removeTap` returns. Installing the next tap
    /// then raises an Objective-C exception and aborts the process. Replacing
    /// the graph makes restarts deterministic and avoids that unrecoverable
    /// duplicate-tap path entirely.
    private var avEngine: AVAudioEngine?
    private var inputConverter: NativeInputConverter?
    var engineConfigurationChangeHandler: (() -> Void)?

    /// Optional tap that receives raw pre-DSP audio (48 kHz mono float32).
    /// Used by VoicePreview to capture a test clip. RT-safe requirement:
    /// the closure must not allocate or lock.
    var rawAudioTap: ((UnsafePointer<Float>, Int) -> Void)?

    /// The target format the ring expects. Fixed: 48 kHz, mono, float32.
    /// Native input buffers are explicitly converted to this format after the
    /// tap because AVAudioInputNode itself does not support conversion.
    private let ringFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Scratch buffer holding mono 48 kHz samples for DSP processing.
    /// Sized generously — some macOS input paths hand us ~4800-frame blocks
    /// even when the tap requests 512, and route changes can briefly grow that.
    private var processingBuffer = [Float](repeating: 0, count: MicCapture.maxProcessingFrames)

    private var tapInstalled = false
    private var engineConfigurationObserver: NSObjectProtocol?
    private var hasLoggedFirstInputBuffer = false

    init(engineBridge: AudioEngineBridge, ringBridge: RingBufferBridge) {
        self.engineBridge = engineBridge
        self.ringBridge = ringBridge
    }

    deinit {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Start capture.
    ///
    /// - Parameter deviceID: Optional Core Audio device ID to bind the input
    ///   to. Pass `nil` to use the system default. Passing a specific device
    ///   is how the user "picks a microphone" in the UI.
    ///
    /// Throws on permission denial, device binding failure, or engine setup
    /// failure.
    func start(deviceID: AudioDeviceID? = nil) async throws {
        try await requestMicrophonePermission()

        stop()

        let engine = AVAudioEngine()
        avEngine = engine
        observeConfigurationChanges(for: engine)

        do {
            // Treat the current system default as an explicit device for this
            // capture session. During a route change AUHAL first constructs an
            // input unit against a placeholder/default output device and only
            // then switches it to the requested input. Building the graph in
            // that transient state bakes the wrong format into the connection.
            let resolvedDeviceID = deviceID ?? AudioDeviceEnumerator.defaultInputDevice()?.deviceID
            var resolvedNativeFormat: AVAudioFormat?
            if let id = resolvedDeviceID {
                try bindInputDevice(id, to: engine)
                try await waitForStableInputDevice(id, on: engine)
                resolvedNativeFormat = nativeInputFormat(for: id)
                let reportedRate = resolvedNativeFormat?.sampleRate ?? 0
                let reportedChannels = resolvedNativeFormat?.channelCount ?? 0
                logger.notice("Input device ready: id=\(id, privacy: .public), nativeRate=\(reportedRate, privacy: .public), channels=\(reportedChannels, privacy: .public)")
            }

            // The DSP engine always runs at the ring's rate (48 kHz mono).
            try engineBridge.prepare(
                sampleRate: ringFormat.sampleRate,
                maxBlockSize: Int32(Self.maxProcessingFrames)
            )

            // Mark a new writer session so the driver resyncs its read head.
            ringBridge.bumpGeneration()

            // AVAudioInputNode must run in the hardware's native format. A tap
            // asking that node for 48 kHz aborts the process when, for example,
            // a Bluetooth microphone switches to 24 kHz. Passing nil makes the
            // tap follow the format that the hardware actually supplies. The
            // callback then resamples into the ring's fixed format.
            let input = engine.inputNode
            let tapFormat = resolvedNativeFormat ?? input.outputFormat(forBus: 0)
            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                throw MicCaptureError.invalidInputFormat
            }
            guard let converter = NativeInputConverter(
                outputFormat: ringFormat,
                maximumOutputFrames: AVAudioFrameCount(Self.maxProcessingFrames)
            ) else {
                throw MicCaptureError.invalidInputFormat
            }
            inputConverter = converter

            input.installTap(onBus: 0, bufferSize: 512, format: tapFormat) { [weak self, converter] buffer, _ in
                guard let convertedBuffer = converter.convert(buffer) else { return }
                self?.handleInputBuffer(convertedBuffer)
            }
            tapInstalled = true

            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }

        guard let engine = avEngine else {
            tapInstalled = false
            hasLoggedFirstInputBuffer = false
            return
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        inputConverter = nil
        avEngine = nil
        hasLoggedFirstInputBuffer = false
    }

    // MARK: - Processing

    /// Handle one tapped input buffer on the audio thread.
    ///
    /// IMPORTANT: This runs on the audio thread. No allocations, no locks,
    /// no Swift concurrency. Anything non-trivial happens inside the C++
    /// engine or the lock-free ring. The buffer handling here is deliberately
    /// minimal.
    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, frameCount <= processingBuffer.count else { return }
        guard let channelData = buffer.floatChannelData else { return }

        if !hasLoggedFirstInputBuffer {
            hasLoggedFirstInputBuffer = true
            DispatchQueue.main.async { [weak self, frameCount] in
                self?.logger.notice("First input buffer: \(frameCount, privacy: .public) frames @ 48 kHz mono")
            }
        }

        // Copy channel 0 into the processing scratch buffer.
        // NativeInputConverter guarantees 48 kHz mono float32 here.
        processingBuffer.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            base.update(from: channelData[0], count: frameCount)
            rawAudioTap?(UnsafePointer(base), frameCount)
            engineBridge.process(buffer: base, numFrames: Int32(frameCount))
            ringBridge.write(base, numFrames: Int32(frameCount))
        }
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.avEngine === engine else { return }
            self.logger.notice("AVAudioEngine configuration changed; running=\(engine.isRunning, privacy: .public)")
            // Bluetooth activation can post a configuration notification after
            // the graph has already adapted and resumed. Restarting a healthy
            // running engine turns that harmless notification into a loop.
            guard !engine.isRunning else { return }
            self.engineConfigurationChangeHandler?()
        }
    }

    // MARK: - Device binding

    /// Bind `avEngine.inputNode` to a specific Core Audio device.
    ///
    /// AVAudioEngine doesn't expose a "set input device" API directly on
    /// macOS — you set the underlying AUHAL unit's CurrentDevice property.
    /// Must be called before `avEngine.start()`; later changes require a
    /// full stop/start cycle to pick up.
    private func bindInputDevice(_ id: AudioDeviceID, to engine: AVAudioEngine) throws {
        let audioUnit = engine.inputNode.audioUnit
        guard let unit = audioUnit else {
            throw MicCaptureError.deviceBindingFailed(code: -1)
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw MicCaptureError.deviceBindingFailed(code: Int(status))
        }
    }

    /// Wait until AUHAL has actually adopted the requested device and its
    /// native format has stopped changing. AudioUnitSetProperty can return
    /// before the asynchronous device switch has propagated through
    /// AVAudioInputNode; configuring the graph in that window produces a
    /// stale 48 kHz connection for 24 kHz Bluetooth microphones.
    private func waitForStableInputDevice(_ id: AudioDeviceID, on engine: AVAudioEngine) async throws {
        var previousSampleRate: Double?
        var previousChannelCount: AVAudioChannelCount?
        var stableChecks = 0

        for _ in 0..<40 {
            let currentID = currentInputDeviceID(on: engine)
            let format = engine.inputNode.outputFormat(forBus: 0)
            let usableFormat = format.sampleRate > 0 && format.channelCount > 0

            if currentID == id, usableFormat {
                if previousSampleRate == format.sampleRate,
                   previousChannelCount == format.channelCount {
                    stableChecks += 1
                    if stableChecks >= 3 { return }
                } else {
                    previousSampleRate = format.sampleRate
                    previousChannelCount = format.channelCount
                    stableChecks = 0
                }
            } else {
                previousSampleRate = nil
                previousChannelCount = nil
                stableChecks = 0
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        throw MicCaptureError.deviceBindingTimedOut
    }

    private func currentInputDeviceID(on engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : nil
    }

    /// Read the physical device's native input rate and channel count directly
    /// from HAL. AVAudioInputNode can temporarily report 48 kHz before a
    /// Bluetooth microphone activates even though the device is already known
    /// to capture at 24 kHz.
    private func nativeInputFormat(for deviceID: AudioDeviceID) -> AVAudioFormat? {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &rateAddress,
            0,
            nil,
            &rateSize,
            &sampleRate
        ) == noErr, sampleRate > 0 else { return nil }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamSize
        ) == noErr, streamSize > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamSize,
            rawList
        ) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(
            rawList.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channelCount = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channelCount > 0 else { return nil }

        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )
    }

    // MARK: - Permissions

    /// Request microphone permission asynchronously using a checked
    /// continuation. This avoids blocking the MainActor thread (which
    /// DispatchSemaphore.wait would do) and correctly suspends the Swift
    /// concurrency task until TCC responds.
    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw MicCaptureError.microphonePermissionDenied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    continuation.resume(returning: ok)
                }
            }
            if !granted { throw MicCaptureError.microphonePermissionDenied }
        @unknown default:
            throw MicCaptureError.microphonePermissionDenied
        }
    }
}

enum MicCaptureError: LocalizedError {
    case microphonePermissionDenied
    case deviceBindingFailed(code: Int)
    case deviceBindingTimedOut
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was not granted. Enable it in System Settings → Privacy & Security → Microphone."
        case .deviceBindingFailed(let code):
            return "Could not bind to the selected input device (code \(code))."
        case .deviceBindingTimedOut:
            return "The selected input device did not become ready in time. Try selecting it again."
        case .invalidInputFormat:
            return "The selected input device did not provide a usable audio format."
        }
    }
}
