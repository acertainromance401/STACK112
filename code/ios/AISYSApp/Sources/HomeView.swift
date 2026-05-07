import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var runtime: AppRuntimeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI SYS")
                        .font(.largeTitle.bold())
                    Text("Scan cases, summarize key issues, and practice with quizzes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    quickActionCard(
                        title: "Start OCR Analysis",
                        subtitle: "Capture or pick images to run OCR and IR extraction",
                        systemImage: "doc.viewfinder",
                        tint: .indigo
                    ) {
                        runtime.selectedTab = 1
                    }

                    quickActionCard(
                        title: "Search Cases",
                        subtitle: "Find precedents by case number or legal issue",
                        systemImage: "magnifyingglass",
                        tint: .blue
                    ) {
                        runtime.selectedTab = 2
                    }

                    quickActionCard(
                        title: "Review Notebook",
                        subtitle: "Revisit saved cases and incorrect answers",
                        systemImage: "bookmark",
                        tint: .teal
                    ) {
                        runtime.selectedTab = 3
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Home")
    }

    private func quickActionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
