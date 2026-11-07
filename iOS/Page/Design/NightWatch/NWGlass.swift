import SwiftUI

/// Eased gradient stops for a ramp: `alpha(t)` sampled at `steps + 1` points,
/// so a glow rises with no visible step or band.
func nwRampStops(_ color: NightWatch.RGBA, steps: Int = 14, alpha: (Double) -> Double) -> [Gradient.Stop] {
    (0...steps).map { i in
        let t = Double(i) / Double(steps)
        return Gradient.Stop(color: color.opacity(alpha(t)).color, location: t)
    }
}

/// The glass of a Night Watch surface, raised off the page: lit from above
/// (a fill a shade lighter at the top, a bright lip along the top edge, a rim
/// that fades down the sides) and casting a soft shadow, so a card reads as
/// an object on the page rather than a box drawn on it. The "Card glow"
/// setting (`\.nwCardGlow`) decides whether a soft light also rises from the
/// bottom edge. Off (the default) draws no light at all. When on, the light
/// follows the card's own rounded outline (a blurred inner stroke, masked so
/// it fades smoothly upwards) and a faint wash; it never stops at a hard edge
/// and never leaves the card's corners.
///
/// `tint` gives the surface a state's colour (amber for a stuck session, teal
/// for a finished turn): its rim and a faint light from the top edge, never
/// mixed into the fill, so the fill keeps its own clean neutral and the
/// colour stays clean. That is the card's own colour, not the glow, so it
/// stays with the glow Off.
struct NWGlassBackground: View {
    var radius: CGFloat = NightWatch.Radius.card
    var fill: NightWatch.RGBA = NightWatch.Palette.surface.opacity(0.92)
    var tint: NightWatch.RGBA? = nil
    var rim = true
    /// False for a surface that sits inside another (an inset, a well): no shadow.
    var raised = true
    @Environment(\.nwCardGlow) private var glow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let top = fill.mixed(with: NightWatch.RGBA(1, 1, 1, fill.a), 0.045)
        ZStack {
            shape.fill(LinearGradient(colors: [top.color, fill.color], startPoint: .top, endPoint: .bottom))
            // Light catching the top of the glass.
            shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.05), location: 0),
                                              .init(color: Color.white.opacity(0), location: 0.4)],
                                      startPoint: .top, endPoint: .bottom))
            // A tint's own alpha is its strength (a session turning stuck fades its amber in).
            if let tint {
                shape.fill(RadialGradient(colors: [tint.opacity(0.13 * tint.a).color, tint.opacity(0).color],
                                          center: .top, startRadius: 0, endRadius: 260))
            }
            if glow.isOn { NWCardGlowLight(radius: radius, glow: glow) }
            if rim {
                // The lit lip along the top edge, fading down the sides.
                shape.strokeBorder(LinearGradient(
                    stops: [.init(color: Color.white.opacity(0.22), location: 0),
                            .init(color: Color.white.opacity(0.06), location: 0.35),
                            .init(color: Color.white.opacity(0.04), location: 1)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if let tint {
                    shape.strokeBorder(LinearGradient(colors: [tint.opacity(0.62 * tint.a).color, tint.opacity(0.22 * tint.a).color],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                if glow.isOn {
                    NWCardGlowRim(radius: radius, glow: glow)
                    // glass.glsl's edge light along the top-left rim (Metal; still, no clock).
                    NWGlassEdgeLight(radius: radius)
                }
            }
        }
        .shadow(color: Color.black.opacity(raised ? 0.6 : 0), radius: 20, x: 0, y: 14)
        .shadow(color: (tint ?? NightWatch.RGBA(0, 0, 0)).opacity(raised ? (tint.map { 0.16 * $0.a } ?? 0.35) : 0).color,
                radius: tint == nil ? 2 : 18, x: 0, y: tint == nil ? 1 : 8)
    }
}

/// The inner light: a wide, soft wash plus a blurred stroke that hugs the
/// rounded outline, both masked with an eased bottom-weighted ramp. Drawn
/// inside the shape (clipped to it), so it follows the corners.
struct NWCardGlowLight: View {
    var radius: CGFloat
    var glow: CardGlow
    private let tint = NightWatch.Palette.glass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let reach = glow.reach
        ZStack {
            // Wash: an ellipse centred on the bottom edge.
            shape.fill(EllipticalGradient(
                stops: nwRampStops(tint) { t in glow.lightAlpha(at: 1 - t) * 0.5 },
                center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.85))
            // Edge light: the outline, blurred inwards.
            shape.strokeBorder(tint.opacity(glow.bottomAlpha * 1.4).color, lineWidth: 5)
                .blur(radius: 7)
                .mask(LinearGradient(stops: nwRampStops(.init(1, 1, 1)) { t in
                    glow.lightAlpha(at: (t - (1 - reach)) / reach) / max(0.0001, glow.bottomAlpha)
                }, startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// The rim's glow: the outline warms towards the bottom along an eased ramp
/// (zero over the top half).
struct NWCardGlowRim: View {
    var radius: CGFloat
    var glow: CardGlow

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: nwRampStops(NightWatch.Palette.glass) { glow.rimAlpha(at: $0) },
                startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// Just the rim of a glass surface, for drawing above content that fills the
/// whole shape (an aurora header).
struct NWGlassRim: View {
    var radius: CGFloat = NightWatch.Radius.card
    /// False when the surface under this rim already draws the glow (a glass
    /// background): the hairline alone is repeated, never the glow twice.
    var withGlow = true
    @Environment(\.nwCardGlow) private var glow

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            if withGlow, glow.isOn { NWCardGlowRim(radius: radius, glow: glow) }
        }
        .allowsHitTesting(false)
    }
}

/// A glass card around its content.
struct NWGlassCard<Content: View>: View {
    var radius: CGFloat = NightWatch.Radius.card
    var padding: CGFloat = NightWatch.Space.lg
    var tint: NightWatch.RGBA? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: radius, tint: tint))
    }
}

// MARK: - Depth: jewels and the desk

/// The surface of something that needs you: a saturated colour lit from its
/// top corner, the one loud thing on the page. Each is a designed ramp of
/// opaque colours (never a hue faded into the grey surface, which turns red to
/// maroon and amber to brown), and every point of it holds white text at
/// 4.5:1 or better, the lit corner included (`lightStrength` is kept to that).
struct NWJewel: Equatable {
    /// The lit corner (top leading) and the far one (bottom trailing).
    let top: NightWatch.RGBA
    let bottom: NightWatch.RGBA
    /// Its rim, its glow and the light that falls into the top corner.
    let light: NightWatch.RGBA
    let lightStrength: Double

    /// A jewel from its table row (`JewelTone.ramp`, shared with Android and the tests).
    init(_ ramp: JewelRamp) {
        self.init(top: .init(hex: ramp.top), bottom: .init(hex: ramp.bottom), light: .init(hex: ramp.light), lightStrength: ramp.lightStrength)
    }

    init(top: NightWatch.RGBA, bottom: NightWatch.RGBA, light: NightWatch.RGBA, lightStrength: Double) {
        self.top = top; self.bottom = bottom; self.light = light; self.lightStrength = lightStrength
    }

    /// Irreversible: crimson.
    static let red = NWJewel(JewelTone.red.ramp)
    /// Considered: deep sky.
    static let sky = NWJewel(JewelTone.sky.ramp)
    /// Undoable: emerald.
    static let green = NWJewel(JewelTone.green.ramp)
    /// A question, anything amber: ember.
    static let amber = NWJewel(JewelTone.amber.ramp)

    /// Working, a finished turn: deep teal.
    static let teal = NWJewel(JewelTone.teal.ramp)
    // A project's own colours (`ProjectHue`), for its doors and bands. Rose leans plum and white
    // leans indigo, so neither reads as Irreversible's crimson or as grey.
    static let lime = NWJewel(JewelTone.lime.ramp)
    static let violet = NWJewel(JewelTone.violet.ramp)
    static let plum = NWJewel(JewelTone.plum.ramp)
    static let indigo = NWJewel(JewelTone.indigo.ramp)

    /// The jewel of a row's colour (`NowRow.tint`) or a section's.
    static func of(_ tint: NightWatch.RGBA?) -> NWJewel {
        switch tint {
        case NightWatch.Palette.red?: return .red
        case NightWatch.Palette.sky?: return .sky
        case NightWatch.Palette.green?: return .green
        case NightWatch.Palette.teal?: return .teal
        case NightWatch.Palette.violet?: return .violet
        default: return .amber
        }
    }

    /// A project's jewel.
    static func of(_ hue: ProjectHue) -> NWJewel { NWJewel(JewelTone(hue: hue).ramp) }
}

/// A jewel's surface: its ramp, the light in its top corner, a bright lip, a
/// rim in its own light and a glow of that light under it. Opaque.
struct NWJewelSurface: View {
    var jewel: NWJewel
    var radius: CGFloat = NightWatch.Radius.card
    /// How far it stands off the page: its glow's reach and drop.
    var lift: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [jewel.top.color, jewel.bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0).color],
                                      center: .topLeading, startRadius: 0, endRadius: 300))
            // The gloss: light across the top, gone a third of the way down.
            shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.06), location: 0),
                                              .init(color: Color.white.opacity(0), location: 0.35)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [jewel.light.opacity(0.85).color, jewel.light.opacity(0.22).color],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // The lip: light catching the top edge.
            shape.strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(0.42), location: 0),
                                                      .init(color: Color.white.opacity(0), location: 0.3)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        // Lift, on a dark page, is light: its own colour glowing under it, then a short dark contact shadow.
        .shadow(color: jewel.light.opacity(0.36 * min(1, lift)).color, radius: 24 * lift, x: 0, y: 14 * lift)
        .shadow(color: Color.black.opacity(0.55), radius: 4, x: 0, y: 3)
    }
}

/// An icon tile: a small glossy squircle of a jewel with a white glyph, the way
/// a section, a card or a session is marked. `glass` is for a tile that sits
/// on a jewel already: clear glass, so it does not vanish into its own colour.
struct NWIconTile: View {
    var symbol: String
    var jewel: NWJewel
    var size: CGFloat = 30
    var glass = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundColor(.white)
            .shadow(color: (glass ? jewel.light : NightWatch.RGBA(0, 0, 0)).opacity(glass ? 0.8 : 0.3).color, radius: glass ? 6 : 1, x: 0, y: glass ? 0 : 1)
            .frame(width: size, height: size)
            .background(ZStack {
                if glass {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(LinearGradient(colors: [jewel.light.mixed(with: jewel.top, 0.45).color, jewel.top.color, jewel.bottom.color],
                                              startPoint: .top, endPoint: .bottom))
                    shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.3), location: 0),
                                                      .init(color: Color.white.opacity(0), location: 0.5)],
                                              startPoint: .top, endPoint: .bottom))
                }
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(glass ? 0.45 : 0.5), Color.white.opacity(0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            })
            .shadow(color: jewel.light.opacity(glass ? 0 : 0.45).color, radius: size * 0.25, x: 0, y: size * 0.12)
            .accessibilityHidden(true)
    }
}

/// A soft tile: a faint tint of a colour with the glyph in it, for the quiet
/// rows (a session's facts, Settled), which are marked but never loud.
struct NWSoftTile: View {
    var symbol: String
    var tint: NightWatch.RGBA
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(tint.color)
            .frame(width: size, height: size)
            .background(ZStack {
                shape.fill(LinearGradient(colors: [tint.opacity(0.2).color, tint.opacity(0.08).color], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(LinearGradient(colors: [tint.opacity(0.4).color, tint.opacity(0.1).color], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            })
            .accessibilityHidden(true)
    }
}

/// The band across the top of a session's card: its project's jewel, so each
/// session wears its own colour, lit along its top edge.
struct NWHueBand: View {
    var jewel: NWJewel
    var radius: CGFloat = NightWatch.Radius.card

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                           topTrailingRadius: radius, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(colors: [jewel.top.color, jewel.bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0).color],
                                      center: .topLeading, startRadius: 0, endRadius: 260))
            shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.07), location: 0),
                                              .init(color: Color.white.opacity(0), location: 0.5)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(0.4), location: 0),
                                                      .init(color: jewel.light.opacity(0.3).color, location: 0.4),
                                                      .init(color: jewel.light.opacity(0).color, location: 1)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Rectangle().fill(jewel.light.opacity(0.35).color).frame(height: 1)
        }
    }
}

/// The desk: the raised surface the work sits on, below the sky. Its top edge
/// is where the information above (the Horizon, the Runway) ends and what
/// needs you begins: a lit lip with the mood's light along it, like the line
/// where the sky meets the ground.
struct NWDesk: View {
    /// The mood's colour: amber when something needs you, teal while agents work.
    var light: NightWatch.RGBA
    var radius: CGFloat = 32

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                           topTrailingRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(LinearGradient(stops: [.init(color: NightWatch.RGBA(hex: 0x0E1322).color, location: 0),
                                              .init(color: NightWatch.RGBA(hex: 0x0A0E1A).color, location: 0.1),
                                              .init(color: NightWatch.RGBA(hex: 0x070A13).color, location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            // The mood's light, washing a little way down from the edge and gone before the wash's own edge.
            Rectangle().fill(RadialGradient(colors: [light.opacity(0.12).color, light.opacity(0).color],
                                            center: .top, startRadius: 0, endRadius: 280))
                .frame(height: 300)
                .clipShape(shape)
            // The lip, only along the top.
            shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                .mask(VStack(spacing: 0) {
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                    Spacer(minLength: 0)
                })
            // The horizon line: brightest in the middle, gone at the corners.
            ZStack {
                Capsule().fill(LinearGradient(colors: [light.opacity(0).color, light.opacity(0.7).color, light.opacity(0).color],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6).blur(radius: 5)
                Capsule().fill(LinearGradient(colors: [light.opacity(0).color, light.opacity(0.9).color, light.opacity(0).color],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1.2)
            }
            .padding(.horizontal, radius + 8)
        }
        .shadow(color: Color.black.opacity(0.7), radius: 26, x: 0, y: -6)
        .allowsHitTesting(false)
    }
}

/// The Runway's glass: an instrument lifted off the sky, floating across the
/// desk's edge. Smoked glass lit from above, standing on the mood's light. It
/// holds only information, so it carries no colour of its own.
struct NWInstrumentGlass: View {
    var light: NightWatch.RGBA
    var radius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [NightWatch.RGBA(hex: 0x182035, alpha: 0.94).color, NightWatch.RGBA(hex: 0x0B1020, alpha: 0.96).color],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.07), location: 0),
                                              .init(color: Color.white.opacity(0), location: 0.45)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [light.opacity(0.1).color, light.opacity(0).color], center: .bottom, startRadius: 0, endRadius: 220))
            shape.strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(0.26), location: 0),
                                                      .init(color: Color.white.opacity(0.07), location: 0.4),
                                                      .init(color: light.opacity(0.35).color, location: 1)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: light.opacity(0.22).color, radius: 26, x: 0, y: 16)
        .shadow(color: Color.black.opacity(0.65), radius: 14, x: 0, y: 10)
    }
}

/// Depth while scrolling: a card leaving the top of the stream recedes into the
/// sky, a little smaller and dimmer, and comes forward again as it returns.
/// Only at the top edge, so nothing under the nav capsule is ever distorted;
/// still with Reduce Motion.
struct NWRecede: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwReduceMotion) private var forcedReduceMotion

    func body(content: Content) -> some View {
        content.scrollTransition(topLeading: .interactive, bottomTrailing: .identity) { c, phase in
            let still = reduceMotion || forcedReduceMotion || phase.isIdentity
            return c.scaleEffect(still ? 1 : 0.94, anchor: .bottom)
                .opacity(still ? 1 : 0.55)
        }
    }
}

extension View {
    /// See `NWRecede`.
    func nwRecedes() -> some View { modifier(NWRecede()) }
}

/// The page background: the night sky's darkness with a whisper of violet at
/// the top. There is deliberately no light at the bottom: any glow comes
/// from the Card glow setting, on the cards themselves.
struct NWBackdrop: View {
    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color
            RadialGradient(colors: [NightWatch.Palette.violet.opacity(0.07).color, .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass

/// Liquid Glass is for the chrome that floats over the sky (the capsule, the
/// Mac chip, the round buttons, the composer, a sheet's close button), never
/// for cards and rows: those keep `NWGlassBackground`, opaque enough to read
/// over a moving aurora. iOS 26 and later only; everywhere else, and with
/// Reduce Transparency on, each piece draws exactly today's surface instead.
/// Every `glassEffect` in the app is in this file, behind that one gate.
extension NightWatch.Palette {
    /// The tint of the chrome's glass: a light smoke of the page's night, so the
    /// glass itself shows (what is under it, bent at its edges, its rim lit) and
    /// white labels still hold over the brightest sky of the day.
    static let chromeGlass = NightWatch.RGBA(hex: 0x04060A, alpha: 0.34)
}

private struct NWLiquidGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the chrome may use Liquid Glass where the system has it. On;
    /// the render harness turns it off (`-NWGlass off`) to draw the fallback.
    var nwLiquidGlass: Bool {
        get { self[NWLiquidGlassKey.self] }
        set { self[NWLiquidGlassKey.self] = newValue }
    }

    /// The gate: the chrome is on glass only where the system draws it
    /// (iOS 26+), the harness allows it and Reduce Transparency is off.
    var nwChromeGlassOn: Bool {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return false }
        return nwLiquidGlass && !accessibilityReduceTransparency
        #else
        return false
        #endif
    }
}

/// One piece of chrome: Liquid Glass in `shape`, tinted, or `fallback` (the
/// surface it had before glass) behind it.
struct NWChromeGlass<S: Shape, Fallback: View>: ViewModifier {
    var shape: S
    var tint: NightWatch.RGBA
    /// Glass that answers a touch. Off for hold surfaces: their ring is the feedback.
    var interactive: Bool
    var fallback: Fallback
    @Environment(\.nwChromeGlassOn) private var glass

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                content.glassEffect(.regular.tint(tint.color).interactive(interactive), in: shape)
            } else {
                content.background(fallback)
            }
        } else {
            content.background(fallback)
        }
        #else
        content.background(fallback)
        #endif
    }
}

/// The selected place in a bar of glass (the nav capsule's side, the room's
/// lens): a brighter bubble of glass inside it, lit along its top edge.
struct NWGlassBubble: View {
    var radius: CGFloat? = nil

    var body: some View {
        let shape = radius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Capsule())
        ZStack {
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            shape.stroke(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}

/// Names a piece of chrome's glass inside an `NWChromeGlassGroup`, so it
/// morphs into its neighbours as it comes and goes. Nothing without glass.
struct NWChromeGlassID<ID: Hashable & Sendable>: ViewModifier {
    var id: ID
    var namespace: Namespace.ID
    @Environment(\.nwChromeGlassOn) private var glass

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                content.glassEffectID(id, in: namespace)
            } else {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Chrome that sits together: one `GlassEffectContainer`, so the pieces
/// share what they refract and can melt into one another. Just the content
/// without glass.
struct NWChromeGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.nwChromeGlassOn) private var glass

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                GlassEffectContainer(spacing: spacing) { content() }
            } else {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// This piece of chrome on Liquid Glass (`NWChromeGlass`), or on `fallback`.
    func nwChromeGlass<S: Shape, F: View>(in shape: S, tint: NightWatch.RGBA = NightWatch.Palette.chromeGlass, interactive: Bool = true,
                                          @ViewBuilder fallback: () -> F) -> some View {
        modifier(NWChromeGlass(shape: shape, tint: tint, interactive: interactive, fallback: fallback()))
    }

    /// The glass's identity in its group (`NWChromeGlassID`).
    func nwChromeGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(NWChromeGlassID(id: id, namespace: namespace))
    }
}
