import SwiftUI

@MainActor
struct JourneyView: View {
    @Bindable var model: LearningViewModel
    let onLearn: () -> Void
    let onSettings: () -> Void
    private enum Editor: String, Identifiable {
        case add, rename
        var id: String { rawValue }
    }
    @State private var editor: Editor?
    @State private var name = ""
    @State private var showingResetJourney = false

    var body: some View {
        NavigationStack {
            List {
                if let journeys = model.journeys {
                    Section(copy("Wer lernt heute?", "Who's learning today?")) {
                        ForEach(journeys.children) { child in
                            Button {
                                model.selectChild(child.id)
                            } label: {
                                HStack {
                                    Label(child.name, systemImage: "person.crop.circle.fill")
                                    Spacer()
                                    if child.id == journeys.selectedID {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }.frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("child-\(child.name)")
                            .accessibilityAddTraits(child.id == journeys.selectedID ? .isSelected : [])
                        }
                        Button(copy("Kind hinzufügen", "Add child"), systemImage: "person.badge.plus") {
                            name = ""; editor = .add
                        }
                        .disabled(journeys.children.count >= 12)
                        .accessibilityIdentifier("add-child")
                        Button(copy("Namen ändern", "Change name"), systemImage: "pencil") {
                            name = journeys.selected.name; editor = .rename
                        }.accessibilityIdentifier("rename-child")
                    }
                    Section(journeys.selected.name) {
                        LabeledContent(copy("Sterne", "Stars"), value: "\(model.progress.totalStars)")
                        LabeledContent(copy("Richtig", "Correct"), value: "\(model.progress.totalCorrect)")
                        LabeledContent(copy("Noch einmal versucht", "Try-again answers"),
                            value: "\(model.progress.totalAttempts - model.progress.totalCorrect)")
                        Button(copy("Weiterlernen", "Continue learning"), systemImage: "play.circle.fill", action: onLearn)
                            .accessibilityIdentifier("journey-continue")
                        Button(role: .destructive) {
                            showingResetJourney = true
                        } label: {
                            Label(copy("Lernreise zurücksetzen", "Reset journey"), systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityIdentifier("journey-reset")
                        .confirmationDialog(
                            copy("Lernreise von \(journeys.selected.name) zurücksetzen?", "Reset \(journeys.selected.name)'s journey?"),
                            isPresented: $showingResetJourney,
                            titleVisibility: .visible
                        ) {
                            Button(copy("Diese Lernreise löschen", "Erase this journey"), role: .destructive) {
                                model.resetJourney()
                            }
                        } message: {
                            Text(copy("Sterne, Fortschritt und Antworten dieses Kindes werden gelöscht. Andere Kinder behalten ihre Lernreise.",
                                      "This child's stars, progress and answers will be erased. Other children's journeys are kept."))
                        }
                    }
                    Section {
                        ForEach(TimeLearningLevel.allCases) { level in
                            let isCurrent = level == model.progress.level && !model.progress.curriculumCompleted
                            let isMastered = journeys.selected.masteredLevels?.contains(level) == true
                            Button {
                                // Returning to the current stage continues its
                                // exercise. Revisiting another stage starts a
                                // practice round while retaining earned history.
                                if !isCurrent { model.start(level: level) }
                                onLearn()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isMastered ? "checkmark.circle.fill" : isCurrent ? "play.circle.fill" : "circle")
                                        .foregroundStyle(isMastered ? Color.green : Color.accentColor)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(level.title(language: model.language))
                                            .foregroundStyle(.primary)
                                        Text(isCurrent
                                             ? copy("Hier übst du gerade · Weiterüben", "You're practising here · Continue")
                                             : isMastered
                                                ? copy("Geschafft · Noch einmal üben", "Completed · Practise again")
                                                : copy("Diese Stufe üben", "Practise this stage"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if isCurrent {
                                            ProgressView(value: model.progress.masteryFraction(threshold: model.masteryThreshold))
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("journey-level-\(level.rawValue)")
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        }
                    } header: {
                        Text(copy("Deine Lernreise", "Your learning journey"))
                    } footer: {
                        Text(copy("Wähle jederzeit eine Stufe zum Üben. Deine Sterne, Antworten und geschafften Stufen bleiben erhalten.",
                                  "Choose any stage to practise. Your stars, answers and completed stages are kept."))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("journey-practice-note")
                    }
                    Section {
                        if journeys.selected.attempts.isEmpty {
                            Text(copy("Deine Antworten erscheinen hier, sobald du übst.", "Your answers appear here as you practise."))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("journey-empty-answers")
                        }
                        ForEach(journeys.selected.attempts.reversed()) { attempt in
                            HStack(alignment: .top) {
                                Image(systemName: attempt.correct ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                                    .foregroundStyle(attempt.correct ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attempt.correct ? copy("Richtig!", "Correct!") : copy("Noch einmal üben", "Practise again"))
                                        .fontWeight(.semibold)
                                    Text(copy("Uhr: ", "Clock: ") + attempt.target.digitalText(language: model.language)
                                         + copy(" · Deine Antwort: ", " · Your answer: ") + attempt.answer.digitalText(language: model.language))
                                        .font(.subheadline)
                                    Text(attempt.date, format: .dateTime.day().month().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(copy("Letzte Antworten", "Recent answers"))
                    } footer: {
                        Text(copy("Namen, Fortschritt und die letzten 500 Antworten je Kind bleiben auf diesem Gerät.",
                                  "Names, progress and the latest 500 answers per child stay on this device."))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("journey-storage-note")
                    }
                }
            }
            .contentMargins(.bottom, 24, for: .scrollContent)
            .navigationTitle(copy("Meine Lernreise", "My journey"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copy("Zur Uhr", "Back to clock"), systemImage: "chevron.left", action: onLearn)
                        .accessibilityIdentifier("journey-back-to-clock")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copy("Einstellungen", "Settings"), systemImage: "gearshape.fill", action: onSettings)
                }
            }
            .sheet(item: $editor) { mode in
                NavigationStack {
                    Form {
                        TextField(copy("Vorname oder Spitzname", "First name or nickname"), text: $name)
                            .textContentType(.nickname).autocorrectionDisabled()
                            .accessibilityIdentifier("child-name-field")
                            .onChange(of: name) { _, value in name = String(value.prefix(30)) }
                        Text(copy("Der Name bleibt auf diesem Gerät.", "The name stays on this device."))
                    }
                    .navigationTitle(mode == .add ? copy("Neues Kind", "New child") : copy("Name ändern", "Change name"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(copy("Abbrechen", "Cancel")) { editor = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(copy("Speichern", "Save")) {
                                if mode == .add { model.addChild(name: name) }
                                else { model.journeys?.renameSelected(name) }
                                editor = nil
                            }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("save-child")
                        }
                    }
                }
            }
        }
    }

    private func copy(_ de: String, _ en: String) -> String { model.language == .german ? de : en }
}
