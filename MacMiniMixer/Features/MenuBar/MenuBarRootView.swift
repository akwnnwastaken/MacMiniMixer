import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var viewModel: MixerViewModel

    var body: some View {
        MixerPanelView(viewModel: viewModel)
    }
}
