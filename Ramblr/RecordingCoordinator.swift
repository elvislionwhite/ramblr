import SwiftUI
import Combine
import AppKit

class RecordingCoordinator: ObservableObject {
    private var audioManager: AudioManager
    private var transcriptionManager: TranscriptionManager
    private var mediaPlaybackManager: MediaPlaybackManager
    private var notificationObserver: NSObjectProtocol?
    private var lastRecordingURL: URL? // Store the last recording URL for retry
    private var clipboardOnlyRecording = false
    private var cancellables = Set<AnyCancellable>()

    // Push-to-talk state
    private var pttHeld = false
    private var pttPendingStop = false
    private var pttPendingCancel = false
    private var pttPressTime: Date?
    private let pttMinHold: TimeInterval = 0.3 // ignore accidental quick taps

    @Published var transcriptionStatus: String = ""

    init(audioManager: AudioManager, transcriptionManager: TranscriptionManager, mediaPlaybackManager: MediaPlaybackManager) {
        logInfo("RecordingCoordinator: Initializing")
        self.audioManager = audioManager
        self.transcriptionManager = transcriptionManager
        self.mediaPlaybackManager = mediaPlaybackManager

        // Observe audio levels for waveform indicator
        self.audioManager.$audioLevels.sink { levels in
            WaveformIndicatorWindow.shared.updateAudioLevels(levels)
        }.store(in: &cancellables)
        
        // Observe status message updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTranscriptionStatus),
            name: NSNotification.Name("TranscriptionStatusChanged"),
            object: nil
        )
        
        // Store the observer so it doesn't get deallocated
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received hotkey notification")
            self?.toggleRecording()
        }
        // Observe cancel hotkey
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CancelHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received cancel hotkey notification")
            self?.cancelRecording()
        }
        // Observe clipboard hotkey (record without auto-paste)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClipboardHotkeyPressed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logDebug("RecordingCoordinator: Received clipboard hotkey notification")
            self?.toggleRecording(clipboardOnly: true)
        }
        // Push-to-talk: hold to record, release to stop + transcribe
        NotificationCenter.default.addObserver(
            forName: PushToTalkManager.pressedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushToTalkStart()
        }
        NotificationCenter.default.addObserver(
            forName: PushToTalkManager.releasedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushToTalkStop()
        }
        // Recording actually starts asynchronously; observe it to fulfil any deferred PTT action
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RecordingStatusChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            if (note.userInfo?["isRecording"] as? Bool) == true {
                self?.pttHandleRecordingStarted()
            }
        }
    }
    
    @objc private func updateTranscriptionStatus(_ notification: Notification) {
        if let status = notification.userInfo?["status"] as? String {
            DispatchQueue.main.async {
                self.transcriptionStatus = status
            }
        }
    }
    
    // Function to open the log file
    func openLogFile() {
        Logger.shared.openLogFile()
    }

    // Allow manual selection of an audio file to transcribe
    func selectFileForTranscription() {
        logInfo("RecordingCoordinator: Opening file picker for transcription")
        let panel = NSOpenPanel()
        panel.title = "Selecionar arquivo de áudio"
        panel.prompt = "Transcrever"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "mp4", "mkv", "webm", "qta"]

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else { return }
        transcribeSelectedFile(selectedURL)
    }
    
    // Public method for UI to start/stop recording
    func toggleRecordingFromUI() {
        toggleRecording()
    }
    
    // Public method to cancel the current recording without transcribing
    func cancelRecording() {
        guard audioManager.isRecording else { return }
        logInfo("RecordingCoordinator: Cancelling recording at user request")
        mediaPlaybackManager.resumeIfWePaused()

        // Hide waveform indicator
        WaveformIndicatorWindow.shared.hide()
        
        if let url = audioManager.stopRecording() {
            // Move the file next to the default recording file as cancelled.wav
            let dir = url.deletingLastPathComponent()
            let destURL = dir.appendingPathComponent("cancelled.wav")
            // Remove existing cancelled.wav if present
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.moveItem(at: url, to: destURL)
                logInfo("RecordingCoordinator: Saved cancelled recording to \(destURL.path)")
            } catch {
                logError("RecordingCoordinator: Failed to move cancelled recording: \(error)")
            }
        }
        DispatchQueue.main.async {
            self.transcriptionManager.statusMessage = "Gravação cancelada"
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionStatusChanged"),
                object: nil,
                userInfo: ["status": "Gravação cancelada"]
            )
        }
    }
    
    // MARK: - Push-to-Talk

    private func pushToTalkStart() {
        guard !pttHeld else { return }
        guard !audioManager.isRecording else {
            logInfo("RecordingCoordinator: Push-to-talk ignored (already recording)")
            return
        }
        pttHeld = true
        pttPendingStop = false
        pttPendingCancel = false
        pttPressTime = Date()
        logInfo("RecordingCoordinator: Push-to-talk start")
        toggleRecording() // begins recording (not currently recording)
    }

    private func pushToTalkStop() {
        guard pttHeld else { return }
        pttHeld = false
        let elapsed = Date().timeIntervalSince(pttPressTime ?? Date())
        let tooShort = elapsed < pttMinHold
        logInfo("RecordingCoordinator: Push-to-talk stop (held \(String(format: "%.2f", elapsed))s, tooShort=\(tooShort))")
        if audioManager.isRecording {
            if tooShort { cancelRecording() } else { toggleRecording() } // stop + transcribe
        } else {
            // The async recording start has not completed yet; defer the action
            if tooShort { pttPendingCancel = true } else { pttPendingStop = true }
        }
    }

    private func pttHandleRecordingStarted() {
        if pttPendingCancel {
            pttPendingCancel = false
            logInfo("RecordingCoordinator: Firing deferred push-to-talk cancel")
            cancelRecording()
        } else if pttPendingStop {
            pttPendingStop = false
            logInfo("RecordingCoordinator: Firing deferred push-to-talk stop")
            toggleRecording()
        }
    }

    private func toggleRecording(clipboardOnly: Bool = false) {
        logInfo("RecordingCoordinator: toggleRecording called, current state: \(audioManager.isRecording), clipboardOnly: \(clipboardOnly)")

        if audioManager.isRecording {
            logInfo("RecordingCoordinator: Stopping recording...")
            mediaPlaybackManager.resumeIfWePaused()

            if let recordingURL = audioManager.stopRecording() {
                logInfo("RecordingCoordinator: Got recording URL: \(recordingURL)")
                self.lastRecordingURL = recordingURL // Save for potential retry
                logInfo("Recording completed: \(recordingURL.lastPathComponent)")
                
                // Verify the file exists and has data
                if let fileSize = try? FileManager.default.attributesOfItem(atPath: recordingURL.path)[.size] as? Int64 {
                    logInfo("RecordingCoordinator: Recording file size: \(fileSize) bytes")
                    if fileSize > 0 {
                        // Switch to transcribing mode
                        WaveformIndicatorWindow.shared.showTranscribing()
                        transcribeAudio(recordingURL: recordingURL)
                    } else {
                        logError("RecordingCoordinator: Recording file is empty")
                        WaveformIndicatorWindow.shared.hide()
                        showRecordingError()
                    }
                } else {
                    logError("RecordingCoordinator: Could not get recording file size")
                    WaveformIndicatorWindow.shared.hide()
                    showRecordingError()
                }
            } else {
                // Don't show an error - this is likely an intentionally short or silent recording
                logInfo("RecordingCoordinator: Recording was too short or silent")
                WaveformIndicatorWindow.shared.hide()
            }
        } else {
            logInfo("RecordingCoordinator: Starting recording...")
            self.clipboardOnlyRecording = clipboardOnly

            // Pause media if enabled, then start recording
            mediaPlaybackManager.pauseIfPlaying { [weak self] in
                guard let self = self else { return }
                self.audioManager.startRecording()

                // Show waveform indicator with output mode context
                let autoPasteEnabled = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
                WaveformIndicatorWindow.shared.showWaveform(
                    clipboardOnly: clipboardOnly,
                    showOutputMode: autoPasteEnabled
                )
            }
        }
    }
    
    private func transcribeAudio(recordingURL: URL) {
        logInfo("Beginning transcription for file: \(recordingURL.lastPathComponent)")
        
        // Use the new transcribeWithRetry method
        transcriptionManager.transcribeWithRetry(audioURL: recordingURL) { [weak self] text in
            guard let self = self else { return }
            
            if let text = text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                logInfo("RecordingCoordinator: Received transcription: \(trimmed)")
                logInfo("Transcription successful: \(trimmed.prefix(50))...")
                // Hide indicator on successful transcription
                WaveformIndicatorWindow.shared.hide()
                // Read the latest clipboardOnly state (user may have toggled via indicator bubble)
                let clipboardOnly = WaveformIndicatorWindow.shared.clipboardOnly
                self.transcriptionManager.handleTranscriptionOutput(trimmed, clipboardOnly: clipboardOnly)
            } else {
                logError("RecordingCoordinator: Transcription failed after retries")
                // Hide indicator on failed transcription
                WaveformIndicatorWindow.shared.hide()
                DispatchQueue.main.async {
                    self.showTranscriptionErrorWithOptions(recordingURL: recordingURL)
                }
            }
        }
    }

    private func transcribeSelectedFile(_ fileURL: URL) {
        logInfo("RecordingCoordinator: Selected file for transcription: \(fileURL.path)")
        lastRecordingURL = fileURL

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 0 {
            WaveformIndicatorWindow.shared.showTranscribing()
            transcribeAudio(recordingURL: fileURL)
        } else {
            logError("RecordingCoordinator: Selected file is empty or unreadable")
            showFileSelectionError()
        }
    }

    private func showFileSelectionError() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Erro de arquivo"
            alert.informativeText = "Não foi possível ler o arquivo de áudio selecionado. Escolha outro arquivo."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func showRecordingError() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Erro de gravação"
            alert.informativeText = "Falha ao capturar a gravação de áudio. Tente novamente."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    private func showTranscriptionErrorWithOptions(recordingURL: URL) {
        logInfo("Showing transcription error dialog with options")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Erro de transcrição"
            alert.informativeText = "Falha ao transcrever o áudio após várias tentativas. Verifique sua chave de API e a conexão com a internet."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Tentar novamente") // First button (return code: 1000)
            alert.addButton(withTitle: "Mostrar no Finder") // Second button (return code: 1001)
            alert.addButton(withTitle: "Ver registros") // Added third button
            alert.addButton(withTitle: "Cancelar") // Fourth button (return code: 1003)
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn: // Retry
                logInfo("RecordingCoordinator: Retrying transcription")
                self.transcribeAudio(recordingURL: recordingURL)
                
            case .alertSecondButtonReturn: // Show in Finder
                logInfo("RecordingCoordinator: Showing in Finder: \(recordingURL)")
                NSWorkspace.shared.selectFile(recordingURL.path, inFileViewerRootedAtPath: "")
                
            case .alertThirdButtonReturn: // View Logs
                logInfo("RecordingCoordinator: Opening log file")
                self.openLogFile()
                
            default: // Cancel
                logInfo("RecordingCoordinator: Transcription error dismissed")
            }
        }
    }
    
    // Function to retry the last transcription from outside this class if needed
    func retryLastTranscription() {
        if let lastURL = lastRecordingURL {
            logInfo("Retrying last transcription attempt")
            transcribeAudio(recordingURL: lastURL)
        }
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("TranscriptionStatusChanged"), object: nil)
    }
} 
