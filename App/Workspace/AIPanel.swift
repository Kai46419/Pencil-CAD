import SwiftUI

/// KI-Assistent unter der Titelleiste: Auftrag eintippen, diktieren oder mit dem Stift schreiben (Scribble),
/// geplante Schritte als Vorschau ansehen und übernehmen.
struct AIPanel: View {
    @ObservedObject var assistant: AIAssistant
    @FocusState private var isFocused: Bool
    @State private var isEnteringKey = false
    @State private var newKey = ""
    @StateObject private var speech = SpeechInput()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header
                inputRow
                if let error = speech.error {
                    Label(error, systemImage: "mic.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                status
            }
            .frame(width: 440)
        }
        .onAppear { isFocused = true }
        .onDisappear { speech.stop() }
        .alert("API-Schlüssel für Claude", isPresented: $isEnteringKey) {
            SecureField("sk-ant-…", text: $newKey)
            Button("Abbrechen", role: .cancel) { newKey = "" }
            Button("Sichern") {
                assistant.saveKey(newKey)
                newKey = ""
            }
        } message: {
            Text("Der Schlüssel aus console.anthropic.com wird nur im Schlüsselbund dieses iPads gespeichert.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("KI-Assistent")
                .font(.callout.weight(.semibold))
            Spacer()
            Menu {
                Picker("Modell", selection: $assistant.mode) {
                    ForEach(AIAssistant.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button(assistant.hasKey ? "Claude-Schlüssel ersetzen …" : "Claude-Schlüssel eingeben …",
                       systemImage: "key") {
                    isEnteringKey = true
                }
                if assistant.hasKey {
                    Button(role: .destructive, action: assistant.deleteKey) {
                        Label("Claude-Schlüssel löschen", systemImage: "trash")
                    }
                }
                Divider()
                Text(AIAssistant.localAvailable ? "Apple Intelligence: verfügbar"
                     : "Apple Intelligence: nicht verfügbar (ab iPadOS 26)")
                Text(assistant.hasKey ? "Claude: Schlüssel hinterlegt" : "Claude: kein Schlüssel")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 32, height: 28)
            }
            .hoverTip("Modell und Schlüssel")
            Button {
                assistant.cancel()
                assistant.isOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("z. B. Quader 10 × 10 × 10, oben vorne 2 mm Fase", text: $assistant.input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(assistant.send)
                .disabled(assistant.isWorking)
            // Mikrofon: Auftrag sprechen; nach dem Satzende wird er gleich abgeschickt
            Button {
                speech.toggle(text: { assistant.input = $0 }, finished: { spoken in
                    if !spoken.trimmingCharacters(in: .whitespaces).isEmpty { assistant.send() }
                })
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.title3)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
                    .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(assistant.isWorking)
            .hoverTip(speech.isRecording ? "Diktat beenden" : "Auftrag sprechen")
            Button(action: assistant.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isWorking)
            .hoverTip("Senden")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch assistant.state {
        case .idle:
            Text("Beschreibe, was entstehen oder sich ändern soll. Einfache Aufträge plant Apple auf dem Gerät, "
                 + "umfangreichere Claude.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .working(let source):
            HStack(spacing: 8) {
                ProgressView()
                Text("\(source) plant …")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", action: assistant.cancel)
            }
            .font(.footnote)
        case .question(let question):
            Label(question, systemImage: "questionmark.bubble")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        case .ready(let plan, let source):
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.summary)
                    .font(.footnote.weight(.semibold))
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { number, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(step.label)
                    }
                    .font(.footnote)
                }
                HStack {
                    Text("Vorschau von \(source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Verwerfen", role: .destructive, action: assistant.discard)
                        .buttonStyle(.bordered)
                    Button("Übernehmen", action: assistant.accept)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
    }
}
