import SwiftUI

extension View {
    /// A list or form at a readable width, centred on the page, on regular width
    /// only: an iPad row the full width of the screen strands a toggle far from
    /// its label. The large title moves over the column with it, so it doesn't
    /// float at the screen's edge. Goes inside `paper()`, so the page color still
    /// fills the screen. `logo` sets the A Dana Life mark before the title.
    func readableWidth(title: LocalizedStringKey, logo: Bool = false) -> some View {
        modifier(ReadableWidth(title: title, logo: logo))
    }
}

private struct ReadableWidth: ViewModifier {
    let title: LocalizedStringKey
    let logo: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var mark = 34

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content.frame(maxWidth: 640).frame(maxWidth: .infinity)
                .navigationTitle(title)
                .toolbar {
                    // The bar's own large title, drawn over the column and
                    // lined up with its cards' edge, where a full-width list
                    // puts it. The serif matches the appearance proxy's.
                    ToolbarItem(placement: .largeTitle) {
                        largeTitle
                            // ponytail: 20 is the inset-grouped list's regular-width
                            // margin, measured, not read; a system margin change
                            // drifts it, a readable-content guide fixes that.
                            .padding(.leading, 20)
                            .frame(maxWidth: 640, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
        } else if logo {
            content.navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .largeTitle) {
                        // ponytail: 16 is the compact large title's margin, measured
                        // like the regular one above.
                        largeTitle.padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        } else {
            content.navigationTitle(title)
        }
    }

    private var largeTitle: some View {
        HStack(spacing: 10) {
            if logo {
                Image("Logo").resizable().scaledToFit().frame(width: mark, height: mark)
                    .accessibilityLabel(Text(verbatim: "A Dana Life"))
            }
            Text(title).font(.system(.largeTitle, design: .serif, weight: .bold))
        }
    }
}
