import SwiftUI

/// §6.3's type-answer mode: the input, and the diff it turns into.
///
/// Its own view so the study screen keeps one job. Purely presentational — it
/// reports a submission and renders a diff; whether the deck asked for it, and
/// what happens next, belong to the caller.
struct TypeAnswerField: View {
    @Binding var typed: String
    /// `nil` until submitted. Non-nil is what makes this a result rather than an
    /// input.
    var diff: [AnswerDiff.Segment]?
    var isCorrect: Bool
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let diff {
                result(diff)
            } else {
                input
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var input: some View {
        HStack(spacing: 10) {
            TextField("Введи відповідь", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(onSubmit)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Palette.paper, in: .rect(cornerRadius: 14))

            Button("Перевірити", action: onSubmit)
                .font(.subheadline.weight(.semibold))
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task { focused = true }
    }

    private func result(_ diff: [AnswerDiff.Segment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                isCorrect ? "Правильно" : "Не зовсім",
                systemImage: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isCorrect ? Palette.good : Palette.again)

            // One `Text` built by concatenation rather than an HStack of many:
            // a wrapped answer has to break between characters like prose, and
            // stacked views would lay each run out as an unbreakable box.
            diffText(diff)
                .scaledFont(17, relativeTo: .body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(isCorrect ? "Правильно" : Localized.string("Не зовсім. Правильна відповідь: \(expected(diff))"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffText(_ diff: [AnswerDiff.Segment]) -> Text {
        diff.reduce(Text("")) { result, segment in
            result + styled(segment)
        }
    }

    private func styled(_ segment: AnswerDiff.Segment) -> Text {
        switch segment.kind {
        case .same:
            Text(segment.text).foregroundColor(Palette.ink)
        case .extra:
            // Struck through as well as coloured: colour alone is not a
            // distinction for a reader who cannot see it.
            Text(segment.text).foregroundColor(Palette.again).strikethrough()
        case .missing:
            Text(segment.text).foregroundColor(Palette.good).underline()
        }
    }

    private func expected(_ diff: [AnswerDiff.Segment]) -> String {
        diff.filter { $0.kind != .extra }.map(\.text).joined()
    }
}
