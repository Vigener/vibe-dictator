import Cocoa
import Speech
import AVFoundation

// MARK: - Configuration
let hotkeyCode: UInt16 = 111 // F12 Key
let geminiModel = "gemini-2.5-flash" // または "gemini-2.0-flash-lite-preview-02-05"

class VibeDictator {
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var isRecording = false
    private var recognizedText = ""

    func start() {
        requestPermissions()
        setupGlobalHotkey()
        print("Vibe Dictator 起動完了 [スタンバイ]")
        print("  - F12キー: 録音の開始/停止 (トグル)")
        print("  - 終了するには Ctrl+C を押してください")

        // メイン実行ループの開始（常駐）
        NSApplication.shared.run()
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            if authStatus != .authorized {
                print("エラー: 音声認識へのアクセスが許可されていません。システム設定を確認してください。")
                exit(1)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("エラー: マイクへのアクセスが許可されていません。")
                    exit(1)
                }
            }
        default:
            print("エラー: マイクへのアクセスが拒否されています。")
            exit(1)
        }

        // アクセシビリティ権限（グローバルホットキー用）のチェック
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        if !accessEnabled {
            print("警告: アクセシビリティ権限が必要です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可してください。")
        }
    }

    private func setupGlobalHotkey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == hotkeyCode {
                if self.isRecording {
                    self.stopRecordingAndProcess()
                } else {
                    self.startRecording()
                }
            }
        }
    }

    private func startRecording() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("オーディオセッションの設定に失敗しました: \(error)")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("SFSpeechAudioBufferRecognitionRequest object creation failed") }
        recognitionRequest.shouldReportPartialResults = true
        // M4のローカル処理を強制
        if #available(macOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            recognizedText = ""
            print("🎤 録音開始...")
            notify(title: "Vibe Dictator", message: "録音開始")
        } catch {
            print("オーディオエンジンの起動に失敗しました: \(error)")
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                self.recognizedText = result.bestTranscription.formattedString
            }
            if error != nil {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.isRecording = false
            }
        }
    }

    private func stopRecordingAndProcess() {
        print("停止処理中...")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        notify(title: "Vibe Dictator", message: "AIによる整形中...")
        print("元のテキスト: \(recognizedText)")

        // Gemini APIへ送信
        rewriteWithGemini(text: recognizedText) { [weak self] rewrittenText in
            guard let self = self else { return }
            print("整形後テキスト: \(rewrittenText)")
            self.pasteToActiveWindow(text: rewrittenText)
            self.notify(title: "Vibe Dictator", message: "入力完了")
        }
    }

    private func rewriteWithGemini(text: String, completion: @escaping (String) -> Void) {
        guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
            print("エラー: 環境変数 GEMINI_API_KEY が設定されていません。")
            completion(text)
            return
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion("")
            return
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        以下の音声を文字起こししたテキストを、プログラミングや技術的な文脈を考慮して、自然で正確な文章に修正・整形してください。出力は修正後のテキストのみとしてください。余計な解説は不要です。

        \(text)
        """

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("APIリクエストエラー: \(String(describing: error))")
                completion(text)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let rewrittenText = firstPart["text"] as? String {
                    completion(rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    completion(text)
                }
            } catch {
                print("JSONパースエラー: \(error)")
                completion(text)
            }
        }
        task.resume()
    }

    private func pasteToActiveWindow(text: String) {
        DispatchQueue.main.async {
            // クリップボードにコピー
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            // Cmd+V をシミュレート
            let script = "tell application \"System Events\" to keystroke \"v\" using command down"
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    print("AppleScriptエラー: \(error)")
                }
            }
        }
    }

    private func notify(title: String, message: String) {
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\""]
        process.launch()
    }
}

let dictator = VibeDictator()
dictator.start()

// --------------------------------------------------------------------------------------
// JSONから用語集を読み込む関数（簡略化）
func loadTerminology() -> String {
    let path = NSString(string: "~/dotfiles/terminology.json").expandingTildeInPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let terms = json["preferred_terms"] as? [[String: String]] else {
        return ""
    }

    return terms.map { "\($0["from"]!) -> \($0["to"]!)" }.joined(separator: ", ")
}

// リライト時のプロンプト構築（rewriteWithGemini関数内を修正）
let glossary = loadTerminology()
let prompt = """
あなたは優秀なエンジニアリング・アシスタントです。
以下の「音声文字起こしテキスト」を、自然な技術文書として整形してください。

# 変換ルール（優先）:
- 以下の用語ペアが音声に含まれる、または文脈から推測される場合は、右側の表記を優先してください。
  [\(glossary)]
- 執筆者の名前は「\(userName)」です。

# 音声文字起こしテキスト:
\(text)
"""
