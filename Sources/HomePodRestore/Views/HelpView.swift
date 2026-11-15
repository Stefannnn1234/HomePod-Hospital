import SwiftUI
import HomePodRestoreCore

struct HelpView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Help & Credits", subtitle: "Answers to the most common questions, and the people who made this possible.")
                VStack(alignment: .leading, spacing: 18) {
                    supportCard
                    whatThisFixes
                    faq
                    credits
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var supportCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Card {
                Label("Get help", systemImage: "bubble.left.and.bubble.right.fill").font(.headline)
                Text("Stuck? Ask in the Nic's Fix Discord. Click “Copy support info” on the HomePod's card first and paste it into your message — it includes the details people need to help.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(destination: model.discordURL) { Label("Open Discord", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent)
                    Link("Read the full guide", destination: Links.guide)
                }
            }
            Card {
                Label("Support this project", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)
                Text("This app and the prebuilt firmware are free. If it saved your HomePod, a donation helps keep the downloads online and the tools updated.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(destination: model.donateURL) { Label("Donate with PayPal", systemImage: "heart") }
                        .buttonStyle(.borderedProminent).tint(.pink)
                    Link("Professional repair", destination: Links.website)
                }
            }
        }
    }

    private var whatThisFixes: some View {
        Card {
            Text("What a restore can fix").font(.headline)
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Boot loops", systemImage: "checkmark").foregroundStyle(.green)
                    Label("Blinking volume buttons", systemImage: "checkmark").foregroundStyle(.green)
                    Label("Setup or update failures", systemImage: "checkmark").foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("No power at all", systemImage: "xmark").foregroundStyle(.red)
                    Label("Failed storage (NAND) or processor", systemImage: "xmark").foregroundStyle(.red)
                    Label("Other hardware damage", systemImage: "xmark").foregroundStyle(.red)
                }
            }
            .font(.callout)
            Text("Only 1st-gen HomePods (A1639). Not HomePod mini or HomePod 2nd gen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var faq: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Common messages, explained").font(.title3.weight(.semibold))
            Card {
                ForEach(ErrorCatalog.all) { issue in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.explanation)
                            ForEach(Array(issue.suggestions.enumerated()), id: \.offset) { _, s in
                                Label(s, systemImage: "arrow.right.circle")
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Image(systemName: icon(issue)).foregroundStyle(color(issue))
                            Text(issue.title)
                        }
                    }
                    if issue.id != ErrorCatalog.all.last?.id { Divider() }
                }
            }
            Link("Known errors spreadsheet →", destination: Links.knownErrorsSheet).font(.callout)
        }
    }

    private func icon(_ i: KnownIssue) -> String {
        switch i.severity {
        case .normal: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fatal: return i.isHardware ? "cpu" : "xmark.octagon.fill"
        }
    }

    private func color(_ i: KnownIssue) -> Color {
        switch i.severity {
        case .normal: return .blue
        case .warning: return .orange
        case .fatal: return i.isHardware ? .purple : .red
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credits").font(.title3.weight(.semibold))
            Card {
                Text("HomePod USB restores exist thanks to years of work by these people. Please support them.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Credit.all) { c in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.headline)
                            Text(c.role).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ForEach(c.links, id: \.url) { l in
                            Link(l.title, destination: l.url).font(.callout)
                        }
                    }
                    if c.id != Credit.all.last?.id { Divider() }
                }
            }
        }
    }
}
