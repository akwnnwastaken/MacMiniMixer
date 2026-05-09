struct MockApplicationLister: ApplicationListing {
    func listApplications() -> [MixerAppItem] {
        [
            MixerAppItem(id: "fallback:safari", name: "Safari", icon: .systemSymbol("safari.fill"), volume: 72),
            MixerAppItem(id: "fallback:music", name: "Music", icon: .systemSymbol("music.note"), volume: 58),
            MixerAppItem(id: "fallback:spotify", name: "Spotify", icon: .systemSymbol("music.quarternote.3"), volume: 82),
            MixerAppItem(id: "fallback:chrome", name: "Chrome", icon: .systemSymbol("globe"), volume: 64),
            MixerAppItem(id: "fallback:discord", name: "Discord", icon: .systemSymbol("bubble.left.and.bubble.right.fill"), volume: 45)
        ]
    }
}
