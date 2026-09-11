import SwiftUI
import UIKit

@MainActor
public struct LearningView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: LearningViewModel

    private let isVoiceAvailable: Bool
    private let isVoiceRequestEnabled: Bool
    private let showsNextQuestionControl: Bool
    private let customHeroBackgroundData: Data?
    private let onVoiceCoachRequested: (@MainActor (TimeQuestion) -> Void)?

    public init(
        language: LearningLanguage = .german,
        startingLevel: TimeLearningLevel = .fullHour,
        isVoiceAvailable: Bool = false,
        isVoiceRequestEnabled: Bool = true,
        showsNextQuestionControl: Bool = true,
        customHeroBackgroundData: Data? = nil,
        onVoiceCoachRequested: (@MainActor (TimeQuestion) -> Void)? = nil
    ) {
        _viewModel = State(
            initialValue: LearningViewModel(
                language: language,
                startingLevel: startingLevel
            )
        )
        self.isVoiceAvailable = isVoiceAvailable
        self.isVoiceRequestEnabled = isVoiceRequestEnabled
        self.showsNextQuestionControl = showsNextQuestionControl
        self.customHeroBackgroundData = customHeroBackgroundData
        self.onVoiceCoachRequested = onVoiceCoachRequested
    }

    public init(
        viewModel: LearningViewModel,
        isVoiceAvailable: Bool = false,
        isVoiceRequestEnabled: Bool = true,
        showsNextQuestionControl: Bool = true,
        customHeroBackgroundData: Data? = nil,
        onVoiceCoachRequested: (@MainActor (TimeQuestion) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.isVoiceAvailable = isVoiceAvailable
        self.isVoiceRequestEnabled = isVoiceRequestEnabled
        self.showsNextQuestionControl = showsNextQuestionControl
        self.customHeroBackgroundData = customHeroBackgroundData
        self.onVoiceCoachRequested = onVoiceCoachRequested
    }

    public var body: some View {
        let question = viewModel.question
        let palette = question.heroTheme.palette

        ZStack {
            if let customHeroBackgroundData,
               let customImage = UIImage(data: customHeroBackgroundData) {
                Image(uiImage: customImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            LinearGradient(
                colors: [palette.background, .white, palette.background.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            // Generated action art stays clearly recognizable, while the
            // light scrim and glass cards keep teaching text easy to read.
            .opacity(customHeroBackgroundData == nil ? 1 : 0.72)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: WatchLearnSpacing.medium) {
                        header(theme: question.heroTheme)
                        progressCard(palette: palette)
                        questionCard(question: question, palette: palette)
                            .id("current-clock-scroll-target")
                        answerGrid(question: question, palette: palette)
                        voiceFallback(question: question, palette: palette)

                        if let evaluation = viewModel.evaluation {
                            feedbackCard(evaluation: evaluation, palette: palette)
                                .id("answer-feedback-scroll-target")
                                .transition(.scale.combined(with: .opacity))
                        }

                    }
                    .padding(.horizontal, WatchLearnSpacing.medium)
                    .padding(.top, WatchLearnSpacing.small)
                    .padding(.bottom, WatchLearnSpacing.large)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: viewModel.question.id) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo("current-clock-scroll-target", anchor: .top)
                    }
                }
                .onChange(of: viewModel.selectedAnswer) { _, answer in
                    guard answer != nil else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                            scrollProxy.scrollTo("answer-feedback-scroll-target", anchor: .bottom)
                        }
                    }
                }
            }

            if viewModel.evaluation?.isCorrect == true {
                SuccessCelebrationView(palette: palette)
                    .id(viewModel.question.id)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(palette.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsNextQuestionControl, viewModel.canContinue {
                LearningNextQuestionControl(viewModel: viewModel)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: viewModel.evaluation)
        .sensoryFeedback(.success, trigger: viewModel.evaluation?.isCorrect == true)
    }

    private func header(theme: HeroTheme) -> some View {
        HStack(spacing: WatchLearnSpacing.medium) {
            Group {
                if let customHeroBackgroundData,
                   let customImage = UIImage(data: customHeroBackgroundData) {
                    Image(uiImage: customImage)
                        .resizable()
                } else {
                    Image(theme.assetName)
                        .resizable()
                }
            }
                .scaledToFill()
                .frame(width: horizontalSizeClass == .compact ? 56 : 72,
                       height: horizontalSizeClass == .compact ? 56 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                }
                .accessibilityLabel(theme.name(language: viewModel.language))
                .accessibilityIdentifier(
                    customHeroBackgroundData == nil
                        ? "learning-built-in-hero-avatar"
                        : "learning-custom-hero-background"
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(LearningCopy.text(.appTitle, language: viewModel.language))
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                Text(theme.name(language: viewModel.language))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(theme.palette.ink.opacity(0.72))
            }

            Spacer(minLength: 4)
        }
    }

    private func progressCard(palette: HeroPalette) -> some View {
        KidCard {
            VStack(spacing: WatchLearnSpacing.small) {
                HStack {
                    Menu {
                        ForEach(TimeLearningLevel.allCases) { level in
                            Button(level.title(language: viewModel.language)) {
                                viewModel.start(level: level)
                            }
                        }
                    } label: {
                        Label(
                            viewModel.progress.level.shortTitle(language: viewModel.language),
                            systemImage: "flag.checkered"
                        )
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                    }
                    .accessibilityLabel(LearningCopy.text(.selectLevel, language: viewModel.language))

                    Spacer()

                    Label("\(viewModel.progress.totalStars)", systemImage: "star.fill")
                        .foregroundStyle(palette.secondary)
                        .accessibilityLabel(
                            "\(LearningCopy.text(.stars, language: viewModel.language)): \(viewModel.progress.totalStars)"
                        )

                    Label("\(viewModel.progress.currentStreak)", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(
                            "\(LearningCopy.text(.streak, language: viewModel.language)): \(viewModel.progress.currentStreak)"
                        )
                }

                MasteryProgressView(
                    progress: viewModel.progress.masteryFraction(threshold: viewModel.masteryThreshold),
                    color: palette.primary,
                    accessibilityLabel: LearningCopy.text(.mastery, language: viewModel.language)
                )
            }
        }
    }

    private func questionCard(question: TimeQuestion, palette: HeroPalette) -> some View {
        KidCard {
            VStack(spacing: WatchLearnSpacing.small) {
                Text(LearningCopy.text(.questionPrompt, language: viewModel.language))
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .multilineTextAlignment(.center)

                Text(LearningCopy.text(.chooseAnswer, language: viewModel.language))
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.72))

                AnalogClockView(
                    time: question.time,
                    theme: question.heroTheme,
                    language: viewModel.language,
                    showsMinuteTicks: question.level == .fiveMinutes || question.level == .anyMinute
                )
                .frame(maxWidth: horizontalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize ? 230 : 300)
                .padding(.horizontal, WatchLearnSpacing.small)
            }
        }
    }

    private func answerGrid(question: TimeQuestion, palette: HeroPalette) -> some View {
        let columnCount = dynamicTypeSize.isAccessibilitySize
            ? min(2, question.choices.count)
            : question.choices.count

        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: WatchLearnSpacing.small),
                count: max(1, columnCount)
            ),
            spacing: WatchLearnSpacing.small
        ) {
            ForEach(question.choices, id: \.self) { choice in
                Button {
                    viewModel.choose(choice)
                } label: {
                    VStack(spacing: 2) {
                        if viewModel.evaluation != nil {
                            Image(systemName: icon(for: choice, question: question))
                        }
                        Text(choice.digitalText(language: viewModel.language))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .buttonStyle(
                    HeroButtonStyle(
                        color: color(choice: choice, question: question, palette: palette),
                        isProminent: isProminent(choice: choice, question: question),
                        horizontalPadding: 4
                    )
                )
                .disabled(viewModel.evaluation?.isCorrect == true)
                .accessibilityLabel(
                    "\(LearningCopy.text(.tapAnswer, language: viewModel.language)): \(choice.spokenText(language: viewModel.language))"
                )
                .accessibilityIdentifier("answer-choice-\(choice.hour)-\(choice.minute)")
            }
        }
    }

    private func feedbackCard(evaluation: AnswerEvaluation, palette: HeroPalette) -> some View {
        KidCard {
            VStack(alignment: .leading, spacing: WatchLearnSpacing.small) {
                HStack(alignment: .top, spacing: WatchLearnSpacing.small) {
                    Image(systemName: evaluation.isCorrect ? "star.circle.fill" : "lightbulb.max.fill")
                        .font(.title)
                        .foregroundStyle(evaluation.isCorrect ? palette.secondary : palette.primary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(evaluation.message)
                            .font(.system(.title3, design: .rounded, weight: .heavy))
                            .accessibilityIdentifier("answer-feedback")

                        if let hint = evaluation.hint {
                            Text(hint.message)
                                .font(.system(.body, design: .rounded, weight: .medium))
                        } else if !evaluation.explanation.isEmpty {
                            Text(evaluation.explanation)
                                .font(.system(.body, design: .rounded, weight: .medium))
                        }
                    }
                }

                if let reward = evaluation.reward {
                    HStack(spacing: 3) {
                        ForEach(0..<reward.stars, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .foregroundStyle(palette.secondary)
                                .symbolEffect(.bounce, value: reward.stars)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.title2)
                    .accessibilityHidden(true)
                }

            }
        }
    }

    @ViewBuilder
    private func voiceFallback(question: TimeQuestion, palette: HeroPalette) -> some View {
        if isVoiceAvailable, let onVoiceCoachRequested {
            Button {
                onVoiceCoachRequested(question)
            } label: {
                Label(
                    LearningCopy.text(.listenToCoach, language: viewModel.language),
                    systemImage: "waveform.circle.fill"
                )
            }
            .buttonStyle(HeroButtonStyle(color: palette.primary, isProminent: true))
            .disabled(!isVoiceRequestEnabled)
            .accessibilityIdentifier("voice-coach-button")
        } else {
            HStack(alignment: .top, spacing: WatchLearnSpacing.small) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(palette.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LearningCopy.text(.voiceOfflineTitle, language: viewModel.language))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                    Text(LearningCopy.text(.voiceOfflineMessage, language: viewModel.language))
                        .font(.footnote)
                        .foregroundStyle(palette.ink.opacity(0.72))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WatchLearnSpacing.medium)
            .background(palette.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func isProminent(choice: ClockTime, question: TimeQuestion) -> Bool {
        guard let evaluation = viewModel.evaluation else { return true }
        if evaluation.isCorrect {
            return choice == question.time
        }
        return choice == viewModel.selectedAnswer
    }

    private func color(choice: ClockTime, question: TimeQuestion, palette: HeroPalette) -> Color {
        guard let evaluation = viewModel.evaluation else { return palette.primary }
        if evaluation.isCorrect, choice == question.time {
            return .green
        }
        if !evaluation.isCorrect, choice == viewModel.selectedAnswer {
            return .orange
        }
        return palette.primary
    }

    private func icon(for choice: ClockTime, question: TimeQuestion) -> String {
        guard let evaluation = viewModel.evaluation else { return "clock" }
        if evaluation.isCorrect, choice == question.time {
            return "checkmark.circle.fill"
        }
        if !evaluation.isCorrect, choice == viewModel.selectedAnswer {
            return "arrow.counterclockwise.circle.fill"
        }
        return "clock"
    }
}

/// Kept in RootView's shared bottom inset so TabView cannot cover it with
/// the persistent microphone controls or navigation bar.
struct LearningNextQuestionControl: View {
    let viewModel: LearningViewModel

    var body: some View {
        Button {
            viewModel.continueLesson()
        } label: {
            Label(LearningCopy.text(.nextQuestion, language: viewModel.language),
                  systemImage: "arrow.right.circle.fill")
        }
        .accessibilityIdentifier("next-question-button")
        .buttonStyle(HeroButtonStyle(color: viewModel.question.heroTheme.palette.primary))
        .frame(maxWidth: 688)
        .padding(.horizontal, WatchLearnSpacing.medium)
        .padding(.vertical, WatchLearnSpacing.small)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

private struct SuccessCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    let palette: HeroPalette

    private let symbols = [
        "star.fill", "sparkles", "bolt.fill", "star.fill",
        "sparkles", "star.fill", "bolt.fill", "sparkles",
        "star.fill", "sparkles", "bolt.fill", "star.fill"
    ]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(
                x: geometry.size.width / 2,
                y: geometry.size.height * 0.46
            )
            let radius = min(geometry.size.width * 0.42, 190)

            ZStack {
                ForEach(symbols.indices, id: \.self) { index in
                    let angle = Double(index) / Double(symbols.count) * Double.pi * 2
                    let distance = radius * (index.isMultiple(of: 2) ? 1 : 0.72)

                    Image(systemName: symbols[index])
                        .font(.system(size: index.isMultiple(of: 3) ? 30 : 23, weight: .heavy))
                        .foregroundStyle(index.isMultiple(of: 2) ? palette.secondary : palette.primary)
                        .shadow(color: .white.opacity(0.8), radius: 3)
                        .position(center)
                        .offset(
                            x: reduceMotion || isExpanded ? CGFloat(cos(angle)) * distance : 0,
                            y: reduceMotion || isExpanded ? CGFloat(sin(angle)) * distance : 0
                        )
                        .rotationEffect(.degrees(isExpanded ? Double(index * 28) : 0))
                        .scaleEffect(reduceMotion ? 0.82 : (isExpanded ? 1.15 : 0.2))
                        .opacity(reduceMotion ? 0.82 : (isExpanded ? 0 : 1))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.35)) {
                isExpanded = true
            }
        }
    }
}
