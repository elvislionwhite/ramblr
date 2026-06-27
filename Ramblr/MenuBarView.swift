import SwiftUI
import Carbon
import Sparkle

struct MenuBarView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var voiceMemosWatcher: VoiceMemosWatcher
    @ObservedObject var mediaPlaybackManager: MediaPlaybackManager
    @ObservedObject var pushToTalkManager: PushToTalkManager
    let updater: SPUUpdater
    @State private var apiKey: String = UserDefaults.standard.string(forKey: "OpenAIAPIKey") ?? ""
    @State private var groqApiKey: String = UserDefaults.standard.string(forKey: "GroqAPIKey") ?? ""
    @State private var autoPasteEnabled: Bool = (UserDefaults.standard.object(forKey: "AutoPasteEnabled") as? Bool) ?? false
    @State private var showHotkeyChangePopover: Bool = false
    @State private var showCancelHotkeyChangePopover: Bool = false
    @State private var showClipboardHotkeyChangePopover: Bool = false
    @State private var showPTTHotkeyChangePopover: Bool = false
    @State private var saveFolderEnabled: Bool = UserDefaults.standard.bool(forKey: "TranscriptionSaveFolderEnabled")
    @State private var saveFolderPath: String = UserDefaults.standard.string(forKey: "TranscriptionSaveFolderPath") ?? ""
    @State private var saveSubdirectoryFormat: String = UserDefaults.standard.string(forKey: "TranscriptionSaveSubdirectoryFormat") ?? "{year}/{month}/{day}"


    init(audioManager: AudioManager, hotkeyManager: HotkeyManager, transcriptionManager: TranscriptionManager, coordinator: RecordingCoordinator, voiceMemosWatcher: VoiceMemosWatcher, mediaPlaybackManager: MediaPlaybackManager, pushToTalkManager: PushToTalkManager, updater: SPUUpdater) {
        self.audioManager = audioManager
        self.hotkeyManager = hotkeyManager
        self.transcriptionManager = transcriptionManager
        self.coordinator = coordinator
        self.voiceMemosWatcher = voiceMemosWatcher
        self.mediaPlaybackManager = mediaPlaybackManager
        self.pushToTalkManager = pushToTalkManager
        self.updater = updater
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ramblr")
                .font(.headline)
                .padding(.top, 2)
                .padding(.bottom, 2)
            
            HStack {
                Text("Status:")
                if mediaPlaybackManager.isEnabled && mediaPlaybackManager.availabilityError != nil {
                    Text("Pausa de mídia indisponível")
                        .foregroundColor(.red)
                } else if (autoPasteEnabled || mediaPlaybackManager.isEnabled) && !transcriptionManager.hasAccessibilityPermission {
                    Text("Precisa de permissão de Acessibilidade")
                        .foregroundColor(.red)
                } else if audioManager.isRecording {
                    Text("Gravando...")
                        .foregroundColor(.red)
                } else if transcriptionManager.isTranscribing {
                    HStack(spacing: 4) {
                        if !transcriptionManager.statusMessage.isEmpty {
                            Text(transcriptionManager.statusMessage)
                                .foregroundColor(.yellow)
                        } else {
                            Text("Transcrevendo")
                                .foregroundColor(.yellow)
                        }
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                } else if !transcriptionManager.statusMessage.isEmpty {
                    Text(transcriptionManager.statusMessage)
                        .foregroundColor(.orange)
                        .opacity(0.6)
                } else {
                    Text("Pronto")
                        .foregroundColor(.primary)
                }
            }
            
            Divider().padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 8) {
                // Model & API key summary
                HStack(spacing: 4) {
                    if !transcriptionManager.hasRequiredAPIKey {
                        Text("Configure a chave de API para começar")
                            .foregroundColor(.red)
                    } else {
                        Text("Usando \(transcriptionManager.modelDisplayName)")
                            .foregroundColor(.secondary)
                    }
                    Button(action: { openModelSetup() }) {
                        Text(transcriptionManager.hasRequiredAPIKey ? "Alterar" : "Configurar").underline()
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)

                Divider().padding(.top, 6)

                Toggle(isOn: $autoPasteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Colar automaticamente no app ativo")
                        Text("Desligado: copia para a área de transferência + notifica")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: autoPasteEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "AutoPasteEnabled")
                    logInfo("AutoPasteEnabled set to \(newValue)")
                    if newValue {
                        transcriptionManager.checkAccessibilityPermission(shouldPrompt: true)
                    }
                }

                Divider().padding(.top, 6)

                Toggle(isOn: $mediaPlaybackManager.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pausar mídia durante a gravação")
                        Text("Pausa a reprodução e retoma ao terminar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: mediaPlaybackManager.isEnabled) { _, newValue in
                    if newValue {
                        transcriptionManager.checkAccessibilityPermission(shouldPrompt: true)
                    }
                }

                if mediaPlaybackManager.isEnabled, let mediaError = mediaPlaybackManager.availabilityError {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(mediaError)
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }

                Divider().padding(.top, 6)

                Toggle(isOn: $voiceMemosWatcher.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcrever Memorandos de Voz automaticamente")
                        Text("Monitora novas gravações do app Memorandos de Voz da Apple")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if voiceMemosWatcher.isEnabled && voiceMemosWatcher.isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Transcrevendo memorando de voz...")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.top, 2)
                }

                Divider().padding(.top, 6)

                Toggle(isOn: $saveFolderEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Salvar transcrições em uma pasta")
                        HStack(spacing: 4) {
                            if saveFolderEnabled && !saveFolderPath.isEmpty {
                                Button(action: {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: saveFolderPath))
                                }) {
                                    Text("Salvando em \(abbreviatePath(saveFolderPath))")
                                        .underline()
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text("Cada transcrição salva como um arquivo .txt")
                            }
                            if saveFolderEnabled {
                                Button(action: {
                                    SaveFolderPanel.shared.show(
                                        folderPath: saveFolderPath,
                                        subdirectoryFormat: saveSubdirectoryFormat
                                    ) { newPath, newFormat in
                                        saveFolderPath = newPath
                                        saveSubdirectoryFormat = newFormat
                                        transcriptionManager.setSaveFolderPath(newPath.isEmpty ? nil : newPath)
                                        transcriptionManager.setSaveSubdirectoryFormat(newFormat)
                                    }
                                }) {
                                    Text("Configurar").underline()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .onChange(of: saveFolderEnabled) { _, newValue in
                    transcriptionManager.setSaveFolderEnabled(newValue)
                }

                Divider().padding(.top, 6)

                Toggle(isOn: $pushToTalkManager.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Segurar tecla para falar")
                        if pushToTalkManager.isEnabled {
                            HStack(spacing: 4) {
                                Text("Segure")
                                Text(pushToTalkManager.displayString)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("e fale; solte para transcrever.")
                                Button(action: { showPTTHotkeyChangePopover = true }) {
                                    Text("Alterar").underline()
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showPTTHotkeyChangePopover, arrowEdge: .top) {
                                    VStack(spacing: 6) {
                                        Text("Pressione a tecla que quer segurar")
                                            .font(.headline)
                                        Text("Dica: ⌘ direito não atrapalha atalhos")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        PTTKeyCaptureRepresentable(
                                            onCaptured: { kc in
                                                pushToTalkManager.updateKeyCode(kc)
                                                showPTTHotkeyChangePopover = false
                                            },
                                            onCancel: { showPTTHotkeyChangePopover = false }
                                        )
                                        .frame(width: 240, height: 0)
                                    }
                                    .padding(8)
                                    .padding(.top, 6)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        } else {
                            Text("Segure uma tecla pra gravar, solte pra transcrever")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onChange(of: pushToTalkManager.isEnabled) { _, newValue in
                    if newValue {
                        transcriptionManager.checkAccessibilityPermission(shouldPrompt: true)
                    }
                }
            }
            .padding(.vertical, 5)
            
            if (autoPasteEnabled || mediaPlaybackManager.isEnabled) && !transcriptionManager.hasAccessibilityPermission {
                Text("⚠️ Permissão de Acessibilidade necessária")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Abrir Ajustes do Sistema") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                        logInfo("Opening Accessibility settings")
                    }
                }
                .padding(.bottom, 5)
            }
            
            // Start/Stop controls
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: {
                        coordinator.toggleRecordingFromUI()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: audioManager.isRecording ? "stop.circle" : "record.circle")
                            Text(audioManager.isRecording ? "Parar gravação" : "Iniciar gravação")
                        }
                    }
                    .keyboardShortcut(.defaultAction)

                    if audioManager.isRecording {
                        Button(action: {
                            coordinator.cancelRecording()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle")
                                Text("Cancelar")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button(action: {
                    coordinator.selectFileForTranscription()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("Transcrever arquivo...")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
                .disabled(audioManager.isRecording || transcriptionManager.isTranscribing)
            }
            // Hotkey hints and change links
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Pressione")
                    Text(hotkeyManager.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("para iniciar/parar a gravação.")
                    Button(action: { showHotkeyChangePopover = true }) {
                        Text("Alterar").underline()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showHotkeyChangePopover, arrowEdge: .top) {
                        VStack(spacing: 6) {
                            Text("Pressione o atalho desejado")
                                .font(.headline)
                            Text("Inclua modificadores como ⌘ ⌥ ⌃ ⇧")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            KeyCaptureRepresentable(
                                onCaptured: { keyCode, flags in
                                    let carbonMods = HotkeyManager.carbonFlags(from: flags)
                                    hotkeyManager.updateHotkey(keyCode: UInt32(keyCode), modifiers: carbonMods)
                                    showHotkeyChangePopover = false
                                },
                                onCancel: { showHotkeyChangePopover = false }
                            )
                            .frame(width: 200, height: 0)
                        }
                        .padding(8)
                        .padding(.top, 6)
                    }
                }
                if autoPasteEnabled {
                    HStack(spacing: 4) {
                        Text("Pressione")
                        Text(hotkeyManager.clipboardDisplayString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("para gravar na área de transferência.")
                        Button(action: { showClipboardHotkeyChangePopover = true }) {
                            Text("Alterar").underline()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showClipboardHotkeyChangePopover, arrowEdge: .top) {
                            VStack(spacing: 6) {
                                Text("Pressione o atalho desejado")
                                    .font(.headline)
                                Text("Inclua modificadores como ⌘ ⌥ ⌃ ⇧")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                KeyCaptureRepresentable(
                                    onCaptured: { keyCode, flags in
                                        let carbonMods = HotkeyManager.carbonFlags(from: flags)
                                        hotkeyManager.updateClipboardHotkey(keyCode: UInt32(keyCode), modifiers: carbonMods)
                                        showClipboardHotkeyChangePopover = false
                                    },
                                    onCancel: { showClipboardHotkeyChangePopover = false }
                                )
                                .frame(width: 200, height: 0)
                            }
                            .padding(8)
                            .padding(.top, 6)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("Pressione")
                    Text(hotkeyManager.cancelDisplayString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("para cancelar a gravação.")
                    Button(action: { showCancelHotkeyChangePopover = true }) {
                        Text("Alterar").underline()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showCancelHotkeyChangePopover, arrowEdge: .top) {
                        VStack(spacing: 6) {
                            Text("Pressione o atalho desejado")
                                .font(.headline)
                            Text("Inclua modificadores como ⌘ ⌥ ⌃ ⇧")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            KeyCaptureRepresentable(
                                onCaptured: { keyCode, flags in
                                    let carbonMods = HotkeyManager.carbonFlags(from: flags)
                                    hotkeyManager.updateCancelHotkey(keyCode: UInt32(keyCode), modifiers: carbonMods)
                                    showCancelHotkeyChangePopover = false
                                },
                                onCancel: { showCancelHotkeyChangePopover = false }
                            )
                            .frame(width: 200, height: 0)
                        }
                        .padding(8)
                        .padding(.top, 6)
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Divider()
            
            // History section
            if !transcriptionManager.history.isEmpty {
                Text("Histórico")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(transcriptionManager.history.enumerated()), id: \.offset) { _, item in
                        Button(action: {
                            transcriptionManager.copyFromHistory(item)
                        }) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                Text(item)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button(action: {
                    logInfo("Viewing application logs")
                    Logger.shared.openLogFile()
                }) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Ver registros")
                    }
                }

                Spacer()

                if !transcriptionManager.history.isEmpty {
                    Button(action: {
                        transcriptionManager.clearHistory()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Limpar histórico")
                        }
                    }
                }

                Spacer()

                Button(action: {
                    logInfo("User initiated app quit")
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Sair")
                }
            }

            HStack {
                CheckForUpdatesView(updater: updater)
                Spacer()
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            // Refresh accessibility status whenever the menu opens
            transcriptionManager.checkAccessibilityPermission(shouldPrompt: false)
        }
        // Detached panel used instead of sheets for key entry (prevents menu dismissal)
    }

    private func openModelSetup() {
        ModelSetupPanel.shared.show(
            model: transcriptionManager.transcriptionModel,
            openAIKey: apiKey,
            groqKey: groqApiKey
        ) { newModel, newOpenAIKey, newGroqKey in
            apiKey = newOpenAIKey
            groqApiKey = newGroqKey
            transcriptionManager.setAPIKey(newOpenAIKey)
            transcriptionManager.setGroqAPIKey(newGroqKey)
            transcriptionManager.setTranscriptionModel(newModel)
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Key Edit Sheet

// Old in-menu sheet removed in favor of detached NSPanel (KeyEntryPanel)

// NSView-based key capture to reliably receive keyDown with modifiers
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let onCaptured: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void
    
    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onCaptured = onCaptured
        v.onCancel = onCancel
        return v
    }
    
    func updateNSView(_ nsView: KeyCaptureView, context: Context) {}
}

private final class KeyCaptureView: NSView {
    var onCaptured: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        // Capture the keycode and current modifier flags
        onCaptured?(event.keyCode, event.modifierFlags)
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Ignore standalone modifier changes
    }
    
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Push-to-Talk key capture (accepts a regular key OR a lone modifier like right ⌘)

private struct PTTKeyCaptureRepresentable: NSViewRepresentable {
    let onCaptured: (UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PTTKeyCaptureView {
        let v = PTTKeyCaptureView()
        v.onCaptured = onCaptured
        v.onCancel = onCancel
        return v
    }

    func updateNSView(_ nsView: PTTKeyCaptureView, context: Context) {}
}

private final class PTTKeyCaptureView: NSView {
    var onCaptured: ((UInt32) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return } // Esc cancels
        onCaptured?(UInt32(event.keyCode))
    }

    override func flagsChanged(with event: NSEvent) {
        // Capture a lone modifier when it is pressed down (mask bit becomes set)
        let kc = UInt32(event.keyCode)
        let mask = PushToTalkManager.deviceMask(forKeyCode: kc)
        if mask != 0, (event.modifierFlags.rawValue & mask) != 0 {
            onCaptured?(kc)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
