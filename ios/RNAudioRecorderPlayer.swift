//
//  RNAudioRecorderPlayer.swift
//  RNAudioRecorderPlayer
//
//  Created by hyochan on 2021/05/05.
//

import Foundation
import AVFoundation
import QuartzCore

enum RecorderError: LocalizedError {
    case notRecording
    case alreadyRecording
    case failedToResumeRecording
    case recordingFormatNotAvailable
    case failedToLocateRecordingFile
    case failedToCreateRecorder
    case failedToStartRecording
    case recordingPermissionNotGranted
    case audioSessionError(Error)

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Recorder is not recording"
        case .alreadyRecording:
            return "Recorder is already recording"
        case .failedToResumeRecording:
            return "Failed to resume recording"
        case .recordingFormatNotAvailable:
            return "Recording format not available"
        case .failedToLocateRecordingFile:
            return "Failed to locate recording file"
        case .failedToCreateRecorder:
            return "Failed to create recorder"
        case .failedToStartRecording:
            return "Failed to start recording"
        case .recordingPermissionNotGranted:
            return "Recording permission not granted"
        case .audioSessionError(let error):
            // Surface domain + code so JS-side Crashlytics buckets distinguish e.g.
            // AVAudioSessionErrorCodeIsBusy (other audio in progress, e.g. phone call)
            // from AVAudioSessionErrorCodeCannotInterruptOthers, etc.
            let nsError = error as NSError
            return "\(nsError.localizedDescription) [\(nsError.domain) #\(nsError.code)]"
        }
    }
}

@objc(RNAudioRecorderPlayer)
class RNAudioRecorderPlayer: RCTEventEmitter, AVAudioRecorderDelegate {
    // MARK: - Constants

    /// Delay before resuming recording after an audio interruption ends.
    /// This workaround is necessary because some SDKs (e.g., Twilio) erroneously call
    /// `setActive(false)` shortly after the interruption ends (~100ms observed in logs).
    /// The delay ensures the audio session is fully stabilized before reactivation.
    private let interruptionRecoveryDelay: TimeInterval = 0.5

    /// How long to wait for capture to actually engage after `record()` is issued
    /// before treating the start as failed. `AVAudioRecorder.record()` returning `true`
    /// only means the command was accepted — not that the audio session engaged (it may
    /// not be ready immediately after an app-update cold launch). The proof that capture
    /// is live is the recorder's time advancing past zero. See VCS-1961.
    private let captureEngageTimeout: TimeInterval = 1.0
    /// Interval between checks while waiting for capture to engage.
    private let captureEngagePollInterval: TimeInterval = 0.1

    // MARK: - Properties

    var audioSession: AVAudioSession = .sharedInstance()
    var subscriptionDuration: Double = 0.5
    var audioFileURL: URL?

    // Recorder
    var currentAudioRecorder: AVAudioRecorder?
    var recordTimer: Timer? {
        didSet { oldValue?.invalidate() }
    }
    var _meteringEnabled: Bool = false
    // Duration of current recording up until it was last resumed
    var accumulatedRecordingDuration: Double = 0
    // Used to keep track of the total recording duration, accounting for pausing and resuming
    var lastResumeTime: Double?
    // Track if we were recording when an interruption began
    var wasRecordingBeforeInterruption: Bool = false

    // Player
    var pausedPlayTime: CMTime?
    var audioPlayerAsset: AVURLAsset!
    var audioPlayerItem: AVPlayerItem!
    var audioPlayer: AVPlayer!
    var timeObserverToken: Any?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        // Route changes (headphones removed, AirPods disconnected, mic switched, etc.)
        // are a common reason recordings silently fail to resume after pause/interrupt.
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        // Media services reset means the audio server died: every session/recorder is
        // invalidated and we must teardown + recreate. Surface it so JS analytics can
        // explain otherwise-mysterious "Cannot start recording" failures.
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaServicesReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override static func requiresMainQueueSetup() -> Bool {
      return true
    }

    override func supportedEvents() -> [String]! {
        return ["rn-playback", "rn-recordback", "rn-recording-state", "rn-audio-session-event"]
    }

    func updateAudioFileURL(path: String, format: AudioFormatID = kAudioFormatMPEG4AAC) {
        if (path == "DEFAULT") {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = cachesDirectory.appendingPathComponent("sound.\(fileExtension(forAudioFormat: format))")
        } else if (path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://")) {
            audioFileURL = URL(string: path)
        } else {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = cachesDirectory.appendingPathComponent(path)
        }
    }

    /**********               Recorder               **********/

    @objc(startRecorder:audioSets:meteringEnabled:resolve:reject:)
    func startRecorder(path: String,  audioSets: [String: Any], meteringEnabled: Bool, resolve: @escaping RCTPromiseResolveBlock,
       rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {
        startNewRecording(path: path, audioSets: audioSets, meteringEnabled: meteringEnabled) { result in
            switch result {
            case .success(let url):
                self.sendEvent(withName: "rn-recording-state", body: ["state": "recording"])
                resolve(url.absoluteString)
            case .failure(let error):
                reject("RNAudioPlayerRecorder", self.recorderErrorMessage(error), error)
            }
        }
    }

    @objc(pauseRecorder:rejecter:)
    public func pauseRecorder(resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {
        do {
            try pauseCurrentRecording()
            sendEvent(withName: "rn-recording-state", body: ["state": "paused"])
            resolve("Recorder paused!")
        } catch let error as RecorderError {
            reject("RNAudioPlayerRecorder", recorderErrorMessage(error), error)
        } catch {
            reject("RNAudioPlayerRecorder", error.localizedDescription, error)
        }
    }

    @objc(resumeRecorder:rejecter:)
    public func resumeRecorder(resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {
        do {
            try resumeCurrentRecording()
            sendEvent(withName: "rn-recording-state", body: ["state": "recording"])
            resolve("Recorder resumed!")
        } catch let error as RecorderError {
            reject("RNAudioPlayerRecorder", recorderErrorMessage(error), error)
        } catch {
            reject("RNAudioPlayerRecorder", error.localizedDescription, error)
        }
    }

    @objc(stopRecorder:rejecter:)
    public func stopRecorder(resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {
        finishCurrentRecording { result in
            switch result {
            case .success(let url):
                self.sendEvent(withName: "rn-recording-state", body: ["state": "stopped"])
                resolve(url.absoluteString)
            case .failure(let error):
                reject("RNAudioPlayerRecorder", self.recorderErrorMessage(error), error)
            }
        }
    }

    /// Bypasses Swift's `LocalizedError` -> NSError bridging, which sometimes fails to
    /// surface our custom `errorDescription` (especially for the `.audioSessionError`
    /// case that wraps an underlying NSError) and instead leaks just the inner error's
    /// `localizedDescription` to JS. Calling `errorDescription` directly guarantees
    /// JS-side analytics receive the formatted "<description> [<domain> #<code>]" string.
    private func recorderErrorMessage(_ error: RecorderError) -> String {
        return error.errorDescription ?? error.localizedDescription
    }

    @objc(updateRecorderProgress:)
    public func updateRecorderProgress(timer: Timer) -> Void {
        guard let currentAudioRecorder else { return }

        var currentMetering: Float = 0
        if (_meteringEnabled) {
            currentAudioRecorder.updateMeters()
            currentMetering = currentAudioRecorder.averagePower(forChannel: 0)
        }
        let status = [
            "isRecording": currentAudioRecorder.isRecording,
            "currentPosition": getCurrentRecordingDuration() * 1000,
            "currentMetering": currentMetering,
        ] as [String : Any];
        sendEvent(withName: "rn-recordback", body: status)
    }

    @objc(startRecorderTimer)
    func startRecorderTimer() -> Void {
        let timer = Timer(
            timeInterval: self.subscriptionDuration,
            target: self,
            selector: #selector(self.updateRecorderProgress),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .default)
        self.recordTimer = timer
    }

    @objc
    func construct() {
        self.subscriptionDuration = 0.1
    }

    @objc(audioPlayerDidFinishPlaying:)
    public static func audioPlayerDidFinishPlaying(player: AVAudioRecorder) -> Bool {
        return true
    }

    @objc(audioPlayerDecodeErrorDidOccur:)
    public static func audioPlayerDecodeErrorDidOccur(error: Error?) -> Void {
        print("Playing failed with error")
        print(error ?? "")
        return
    }

    @objc(setSubscriptionDuration:)
    func setSubscriptionDuration(duration: Double) -> Void {
        subscriptionDuration = duration
    }

    // handle interrupt events
    @objc
    func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let interruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt
        else { return }

        switch interruptionType {
        case AVAudioSession.InterruptionType.began.rawValue:
            // Capture whether we had an active recording so we can decide to resume later
            wasRecordingBeforeInterruption = currentAudioRecorder?.isRecording ?? false
            guard wasRecordingBeforeInterruption else { break }

            // Capture the system-provided interruption reason so JS-side analytics can
            // distinguish phone-call interruptions from app-suspended / mic-muted /
            // route-disconnected, which all surface here but have different mitigations.
            let reasonName = audioSessionInterruptionReasonName(from: userInfo)
            let secondaryAudioActive = audioSession.secondaryAudioShouldBeSilencedHint

            do {
                try pauseCurrentRecording()
                sendEvent(withName: "rn-recording-state", body: [
                    "state": "interrupted",
                    "reason": reasonName,
                    "secondaryAudioActive": secondaryAudioActive,
                ])
            } catch {
                // We don't expect it to fail to pause the recording
            }
            break
        case AVAudioSession.InterruptionType.ended.rawValue:
            // Only send events if we were recording before the interruption
            guard wasRecordingBeforeInterruption else { break }

            // Only attempt to resume if the system indicates it is allowed
            let options = AVAudioSession.InterruptionOptions(rawValue: userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let shouldResume = options.contains(.shouldResume)
            if shouldResume {
                // Delay before resuming to avoid conflicts with third-party SDKs that may
                // deactivate the audio session shortly after the interruption ends (looking at you, Twilio)
                DispatchQueue.main.asyncAfter(deadline: .now() + interruptionRecoveryDelay) {
                    do {
                        try self.resumeCurrentRecording()
                        self.sendEvent(withName: "rn-recording-state", body: [
                            "state": "recording",
                            "trigger": "auto_resume",
                            "shouldResume": true,
                        ])
                    } catch {
                        // Surface the underlying NSError so JS analytics can tell apart
                        // "still in a call" failures from generic activation errors.
                        let nsError = error as NSError
                        self.sendEvent(withName: "rn-recording-state", body: [
                            "state": "paused",
                            "trigger": "auto_resume_failed",
                            "shouldResume": true,
                            "errorMessage": nsError.localizedDescription,
                            "errorDomain": nsError.domain,
                            "errorCode": nsError.code,
                        ])
                    }
                }
            } else {
                sendEvent(withName: "rn-recording-state", body: [
                    "state": "paused",
                    "trigger": "interruption_ended",
                    "shouldResume": false,
                ])
            }
            wasRecordingBeforeInterruption = false
            break
        default:
            break
        }
    }

    /// Emits route change events (headset plugged/unplugged, AirPods disconnect,
    /// category change, etc.) while a recording is active. We skip when not recording
    /// to keep the noise floor low — these notifications fire constantly during
    /// playback or background app activity.
    @objc
    func handleAudioSessionRouteChange(_ notification: Notification) {
        guard
            currentAudioRecorder != nil,
            let userInfo = notification.userInfo,
            let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let currentRoute = audioSession.currentRoute

        sendEvent(withName: "rn-audio-session-event", body: [
            "type": "route_change",
            "reason": routeChangeReasonName(reason),
            "previousInputs": previousRoute?.inputs.map { $0.portType.rawValue } ?? [],
            "currentInputs": currentRoute.inputs.map { $0.portType.rawValue },
            "previousOutputs": previousRoute?.outputs.map { $0.portType.rawValue } ?? [],
            "currentOutputs": currentRoute.outputs.map { $0.portType.rawValue },
        ])
    }

    /// Audio server crashed — every session/recorder is invalidated. We forward this
    /// as a critical signal to JS analytics so we can correlate it with downstream
    /// "Cannot start recording" / "Recorder is not recording" errors.
    @objc
    func handleMediaServicesReset(_ notification: Notification) {
        sendEvent(withName: "rn-audio-session-event", body: [
            "type": "media_services_reset",
            "wasRecording": currentAudioRecorder != nil,
        ])
    }

    private func routeChangeReasonName(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "new_device_available"
        case .oldDeviceUnavailable: return "old_device_unavailable"
        case .categoryChange: return "category_change"
        case .override: return "override"
        case .wakeFromSleep: return "wake_from_sleep"
        case .noSuitableRouteForCategory: return "no_suitable_route_for_category"
        case .routeConfigurationChange: return "route_configuration_change"
        @unknown default: return "unknown"
        }
    }

    /// Maps the iOS-provided interruption reason to a stable string the JS layer can
    /// forward to analytics. Falls back to "default" for builds older than iOS 14.5
    /// (where the reason key isn't populated) and for unknown future reasons.
    private func audioSessionInterruptionReasonName(from userInfo: [AnyHashable: Any]) -> String {
        if #available(iOS 14.5, *) {
            guard
                let rawReason = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
                let reason = AVAudioSession.InterruptionReason(rawValue: rawReason)
            else { return "default" }

            // .routeDisconnected (iOS 17+) is matched via raw value to keep the source
            // compiling against iOS 16 SDKs without requiring an availability guard.
            switch reason {
            case .default:
                return "default"
            case .appWasSuspended:
                return "app_was_suspended"
            case .builtInMicMuted:
                return "built_in_mic_muted"
            @unknown default:
                if reason.rawValue == 3 { return "route_disconnected" }
                return "unknown"
            }
        }
        return "default"
    }

    private func startNewRecording(path: String, audioSets: [String: Any], meteringEnabled: Bool, completion: @escaping (Result<URL, RecorderError>) -> Void) {
        guard currentAudioRecorder == nil else { return completion(.failure(.alreadyRecording)) }

        _meteringEnabled = meteringEnabled
        guard
            let avFormat: AudioFormatID = avFormat(fromString: audioSets["AVFormatIDKeyIOS"] as? String ?? "alac")
        else { return completion(.failure(.recordingFormatNotAvailable)) }

        let settings = [
            AVSampleRateKey: audioSets["AVSampleRateKeyIOS"] as? Int ?? 44100,
            AVFormatIDKey: avFormat,
            AVNumberOfChannelsKey: audioSets["AVNumberOfChannelsKeyIOS"] as? Int ?? 2,
            AVEncoderAudioQualityKey: audioSets["AVEncoderAudioQualityKeyIOS"] as? Int ?? AVAudioQuality.medium.rawValue,
            AVLinearPCMBitDepthKey: audioSets["AVLinearPCMBitDepthKeyIOS"] as? Int ?? AVLinearPCMBitDepthKey.count,
            AVLinearPCMIsBigEndianKey: audioSets["AVLinearPCMIsBigEndianKeyIOS"] as? Bool ?? true,
            AVLinearPCMIsFloatKey: audioSets["AVLinearPCMIsFloatKeyIOS"] as? Bool ?? false,
            AVLinearPCMIsNonInterleaved: audioSets["AVLinearPCMIsNonInterleavedIOS"] as? Bool ?? false,
            AVEncoderBitRateKey: audioSets["AVEncoderBitRateKeyIOS"] as? Int ?? 128000
        ] as [String: Any]

        updateAudioFileURL(path: path, format: avFormat)
        let avMode = avMode(fromString: audioSets["AVModeIOS"] as? String ?? "default") ?? .default

        // Configure audio session options
        var categoryOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
        // Check if Bluetooth input should be allowed (defaults to true for backward compatibility)
        let allowBluetoothInput = audioSets["AVAllowBluetoothInputIOS"] as? Bool ?? true
        if allowBluetoothInput {
            categoryOptions.insert(.allowBluetooth)
        }

        do {
            try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            try audioSession.setCategory(.playAndRecord, mode: avMode, options: categoryOptions)
            try audioSession.setActive(true)
        } catch {
            return completion(.failure(.audioSessionError(error)))
        }
        audioSession.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { return completion(.failure(.recordingPermissionNotGranted)) }
                guard let audioFileURL = self.audioFileURL else { return completion(.failure(.failedToLocateRecordingFile)) }
                guard let audioRecorder = try? AVAudioRecorder(url: audioFileURL, settings: settings) else { return completion(.failure(.failedToCreateRecorder)) }

                audioRecorder.prepareToRecord()
                audioRecorder.delegate = self
                audioRecorder.isMeteringEnabled = meteringEnabled
                guard audioRecorder.record() else { return completion(.failure(.failedToStartRecording)) }

                self.currentAudioRecorder = audioRecorder

                // `record()` returning true only confirms the command was issued, not that
                // the audio session actually engaged (it may not be ready right after an
                // app-update cold launch). Wait until the recorder's time advances before
                // reporting success, so callers never get a false "started"
                self.verifyCaptureEngaged(audioRecorder, deadline: CACurrentMediaTime() + self.captureEngageTimeout) { engaged in
                    guard engaged, self.currentAudioRecorder === audioRecorder else {
                        audioRecorder.stop()
                        if self.currentAudioRecorder === audioRecorder {
                            self.currentAudioRecorder = nil
                        }
                        try? self.audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                        return completion(.failure(.failedToStartRecording))
                    }
                    self.recordingDidStart()
                    self.startRecorderTimer()
                    completion(.success(audioFileURL))
                }
            }
        }
    }

    /// Polls until capture is confirmed live (the recorder is recording and its time
    /// has advanced past zero) or the deadline passes. Calls `completion(true)` once
    /// capture engages, or `completion(false)` if it never does within the window.
    private func verifyCaptureEngaged(_ recorder: AVAudioRecorder, deadline: CFTimeInterval, completion: @escaping (Bool) -> Void) {
        if recorder.isRecording && recorder.currentTime > 0 {
            return completion(true)
        }
        guard CACurrentMediaTime() < deadline else {
            return completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + captureEngagePollInterval) {
            self.verifyCaptureEngaged(recorder, deadline: deadline, completion: completion)
        }
    }

    private func pauseCurrentRecording() throws {
        recordTimer = nil;
        guard let currentAudioRecorder else { throw RecorderError.notRecording }

        currentAudioRecorder.pause()
        self.recordingDidPause()
    }

    private func resumeCurrentRecording() throws {
        guard let currentAudioRecorder else { throw RecorderError.notRecording }

        // Reactivate session
        do {
            try audioSession.setActive(true)
        } catch {
            print("[RNAudioRecorderPlayer] Failed to reactivate audio session: \(error.localizedDescription)")
            throw RecorderError.audioSessionError(error)
        }

        // Resume recording
        if currentAudioRecorder.record() == false {
            print("[RNAudioRecorderPlayer] Failed to resume recording")
            throw RecorderError.failedToResumeRecording
        }

        self.recordingDidResume()
        if (self.recordTimer == nil) {
            self.startRecorderTimer()
        }
    }

    private func finishCurrentRecording(completion: @escaping (Result<URL, RecorderError>) -> Void) {
        recordTimer = nil
        DispatchQueue.main.async {
            guard let currentAudioRecorder = self.currentAudioRecorder else { return completion(.failure(.notRecording)) }
            guard let audioFileURL = self.audioFileURL else { return completion(.failure(.failedToLocateRecordingFile)) }

            currentAudioRecorder.stop()
            self.recordingDidFinish()
            self.currentAudioRecorder = nil
            // Deactivate audio session when finished recording
            do {
                try self.audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                completion(.success(audioFileURL))
            } catch {
                completion(.failure(.audioSessionError(error)))
            }
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("[RNAudioRecorderPlayer] Recording finished unsuccessfully")
            self.currentAudioRecorder = nil
            self.recordTimer = nil
            self.recordingDidFinish()
            self.sendEvent(withName: "rn-recording-state", body: ["state": "error"])
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[RNAudioRecorderPlayer] Encode error: \(error?.localizedDescription ?? "unknown")")
        self.currentAudioRecorder = nil
        self.recordTimer = nil
        self.recordingDidFinish()
        self.sendEvent(withName: "rn-recording-state", body: ["state": "error"])
    }

    /**********               Player               **********/

    func addPeriodicTimeObserver() {
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: subscriptionDuration, preferredTimescale: timeScale)

        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: time,
                                                                queue: .main) {_ in
            if (self.audioPlayer != nil) {
                self.sendEvent(withName: "rn-playback", body: [
                    "isMuted": self.audioPlayer.isMuted,
                    "currentPosition": self.audioPlayerItem.currentTime().seconds * 1000,
                    "duration": self.audioPlayerItem.asset.duration.seconds * 1000,
                    "isFinished": false,
                ])
            }
        }
    }

    func removePeriodicTimeObserver() {
        if let timeObserverToken = timeObserverToken {
            audioPlayer.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
    }

    @objc(startPlayer:httpHeaders:resolve:rejecter:)
    public func startPlayer(
        path: String,
        httpHeaders: [String: String],
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [
                AVAudioSession.CategoryOptions.defaultToSpeaker,
                AVAudioSession.CategoryOptions.allowBluetooth,
                AVAudioSession.CategoryOptions.mixWithOthers,
            ])
            try audioSession.setActive(true)
        } catch {
            reject("RNAudioPlayerRecorder", "Failed to play", nil)
        }
        updateAudioFileURL(path: path)
        audioPlayerAsset = AVURLAsset(url: audioFileURL!, options:["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        audioPlayerItem = AVPlayerItem(asset: audioPlayerAsset!)

        if (audioPlayer == nil) {
            audioPlayer = AVPlayer(playerItem: audioPlayerItem)
        } else {
            audioPlayer.replaceCurrentItem(with: audioPlayerItem)
        }

        addPeriodicTimeObserver()
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying), name: Notification.Name.AVPlayerItemDidPlayToEndTime, object: audioPlayer.currentItem)
        audioPlayer.play()
        resolve(audioFileURL?.absoluteString)
    }

    @objc
    public func playerDidFinishPlaying(notification: Notification) {
        if let playerItem = notification.object as? AVPlayerItem {
            let duration = playerItem.duration.seconds * 1000
            self.sendEvent(withName: "rn-playback", body: [
                "isMuted": self.audioPlayer?.isMuted as Any,
                "currentPosition": duration,
                "duration": duration,
                "isFinished": true,
            ])
        }
    }

    @objc(stopPlayer:rejecter:)
    public func stopPlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player has already stopped.", nil)
        }

        audioPlayer.pause()
        self.removePeriodicTimeObserver()
        self.audioPlayer = nil;

        resolve(audioFileURL?.absoluteString)
    }

    @objc(pausePlayer:rejecter:)
    public func pausePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is not playing", nil)
        }

        audioPlayer.pause()
        resolve("Player paused!")
    }

    @objc(resumePlayer:rejecter:)
    public func resumePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is null", nil)
        }

        audioPlayer.play()
        resolve("Resumed!")
    }

    @objc(seekToPlayer:resolve:rejecter:)
    public func seekToPlayer(
        time: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is null", nil)
        }

        audioPlayer.seek(to: CMTime(seconds: time / 1000, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        resolve("Resumed!")
    }

    @objc(setVolume:resolve:rejecter:)
    public func setVolume(
        volume: Float,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        audioPlayer.volume = volume
        resolve(volume)
    }

    @objc(setPlaybackSpeed:resolve:rejecter:)
    public func setPlaybackSpeed(
        playbackSpeed: Float,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is null", nil)
        }

        audioPlayer.rate = playbackSpeed
        resolve("setPlaybackSpeed")
    }

    private func avFormat(fromString encoding: String) -> AudioFormatID? {
        switch encoding {
        case "lpcm":
            return kAudioFormatAppleIMA4
        case "ima4":
            return kAudioFormatAppleIMA4
        case "aac":
            return kAudioFormatMPEG4AAC
        case "MAC3":
            return kAudioFormatMACE3
        case "MAC6":
            return kAudioFormatMACE6
        case "ulaw":
            return kAudioFormatULaw
        case "alaw":
            return kAudioFormatALaw
        case "mp1":
            return kAudioFormatMPEGLayer1
        case "mp2":
            return kAudioFormatMPEGLayer2
        case "mp4":
            return kAudioFormatMPEG4AAC
        case "alac":
            return kAudioFormatAppleLossless
        case "amr":
            return kAudioFormatAMR
        case "flac":
            return kAudioFormatFLAC
        case "opus":
            return kAudioFormatOpus
        case "wav":
            return kAudioFormatLinearPCM
        default:
            return nil
        }
    }

    private func avMode(fromString mode: String) -> AVAudioSession.Mode? {
        switch mode {
        case "measurement":
            return .measurement
        case "gamechat":
            return .gameChat
        case "movieplayback":
            return .moviePlayback
        case "spokenaudio":
            return .spokenAudio
        case "videochat":
            return .videoChat
        case "videorecording":
            return .videoRecording
        case "voicechat":
            return .voiceChat
        case "voiceprompt":
            return .voicePrompt
        case "default":
            return .default
        default:
            return nil
        }
    }

    private func fileExtension(forAudioFormat format: AudioFormatID) -> String {
        switch format {
        case kAudioFormatOpus:
            return "ogg"
        case kAudioFormatLinearPCM:
            return "wav"
        case kAudioFormatAC3, kAudioFormat60958AC3:
            return "ac3"
        case kAudioFormatAppleIMA4:
            return "caf"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4CELP, kAudioFormatMPEG4HVXC, kAudioFormatMPEG4TwinVQ, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_Spatial:
            return "m4a"
        case kAudioFormatMACE3, kAudioFormatMACE6:
            return "caf"
        case kAudioFormatULaw, kAudioFormatALaw:
            return "wav"
        case kAudioFormatQDesign, kAudioFormatQDesign2:
            return "mov"
        case kAudioFormatQUALCOMM:
            return "qcp"
        case kAudioFormatMPEGLayer1:
            return "mp1"
        case kAudioFormatMPEGLayer2:
            return "mp2"
        case kAudioFormatMPEGLayer3:
            return "mp3"
        case kAudioFormatMIDIStream:
            return "mid"
        case kAudioFormatAppleLossless:
            return "m4a"
        case kAudioFormatAMR:
            return "amr"
        case kAudioFormatAMR_WB:
            return "awb"
        case kAudioFormatAudible:
            return "aa"
        case kAudioFormatiLBC:
            return "ilbc"
        case kAudioFormatDVIIntelIMA, kAudioFormatMicrosoftGSM:
            return "wav"
        default:
            // Generic file extension for types that don't have a natural
            // file extension
            return "audio"
        }
    }

    /**********    Recorder Helpers (tracking recording duration)    **********/

    private func recordingDidStart() {
        self.accumulatedRecordingDuration = 0
        self.lastResumeTime = CACurrentMediaTime()
    }

    private func recordingDidPause() {
        guard let lastResumeTime else { return }

        self.accumulatedRecordingDuration += CACurrentMediaTime() - lastResumeTime
        self.lastResumeTime = nil
    }

    private func recordingDidResume() {
        self.lastResumeTime = CACurrentMediaTime()
    }

    private func recordingDidFinish() {
        self.accumulatedRecordingDuration = 0
        self.lastResumeTime = nil
    }

    /// Calculates the current total duration of the recording
    private func getCurrentRecordingDuration() -> Double {
        guard let lastResumeTime else { return accumulatedRecordingDuration }

        return accumulatedRecordingDuration + (CACurrentMediaTime() - lastResumeTime)
    }
}
