import Foundation

/// The word a working tab shows while it thinks.
///
/// Claude Code picks one of these per turn in its own TUI, but never sends it
/// over the wire — the headless stream carries no such field — so Plume keeps
/// its own copy rather than reading one from the CLI.
///
/// The word is chosen from the turn's start time, so it stays put for the
/// whole turn instead of flickering on every redraw, and two tabs that start
/// together do not say the same thing.
nonisolated enum WorkingVerb {
    static func forTurn(startedAt: Date) -> String {
        let key = Int(startedAt.timeIntervalSinceReferenceDate * 1000)
        return all[abs(key) % all.count]
    }

    static let all: [String] = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming",
        "Beboppin'", "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing",
        "Boondoggling", "Booping", "Bootstrapping", "Brewing", "Bunning", "Burrowing",
        "Calculating", "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating",
        "Channeling", "Channelling", "Choreographing", "Churning", "Clauding", "Coalescing",
        "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing",
        "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying", "Discombobulating",
        "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating",
        "Embellishing", "Enchanting", "Envisioning", "Fermenting", "Fiddle-faddling", "Finagling",
        "Flambéing", "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering", "Forging",
        "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping", "Garnishing",
        "Generating", "Gesticulating", "Germinating", "Gitifying", "Grooving", "Gusting",
        "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
        "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring",
        "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kerfuffling", "Kneading",
        "Leavening", "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering",
        "Metamorphosing", "Misting", "Moonwalking", "Moseying", "Mulling", "Mustering",
        "Musing", "Nebulizing", "Nesting", "Newspapering", "Noodling", "Nucleating",
        "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing",
        "Philosophising", "Photosynthesizing", "Pollinating", "Pondering", "Pontificating", "Pouncing",
        "Precipitating", "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating",
        "Roosting", "Ruminating", "Sautéing", "Scampering", "Schlepping", "Scurrying",
        "Seasoning", "Shenaniganing", "Shimmying", "Simmering", "Skedaddling", "Sketching",
        "Slithering", "Smooshing", "Sock-hopping", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing",
        "Tempering", "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying",
        "Transfiguring", "Transmogrifying", "Transmuting", "Twisting", "Undulating", "Unfurling",
        "Unravelling", "Vibing", "Waddling", "Wandering", "Warping", "Whatchamacalliting",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling",
        "Zesting", "Zigzagging",
    ]
}
