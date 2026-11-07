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
            // A tint's own alpha is its strength (a session turning stuck fades its amber in).
            if let tint {
                shape.fill(RadialGradient(colors: [tint.opacity(0.13 * tint.a).color, tint.opacity(0).color],
                                          center: .top, startRadius: 0, endRadius: 260))
            }
            if glow.isOn { NWCardGlowLight(radius: radius, glow: glow) }
            if rim {
                // The lit lip along the top edge, fading down the sides.
                shape.strokeBorder(LinearGradient(
                    stops: [.init(color: Color.white.opacity(0.17), location: 0),
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
        .shadow(color: Color.black.opacity(raised ? 0.5 : 0), radius: 16, x: 0, y: 10)
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

    /// Irreversible: crimson.
    static let red = NWJewel(top: .init(hex: 0xA3243A), bottom: .init(hex: 0x4A0E1C), light: .init(hex: 0xFF7A8A), lightStrength: 0.32)
    /// Considered: deep sky.
    static let sky = NWJewel(top: .init(hex: 0x1D62AE), bottom: .init(hex: 0x0B2A55), light: .init(hex: 0x7CC8FF), lightStrength: 0.15)
    /// Undoable: emerald.
    static let green = NWJewel(top: .init(hex: 0x0B6E51), bottom: .init(hex: 0x05352A), light: .init(hex: 0x5EEAB0), lightStrength: 0.12)
    /// A question, anything amber: ember.
    static let amber = NWJewel(top: .init(hex: 0x9A4A08), bottom: .init(hex: 0x451A05), light: .init(hex: 0xFFB347), lightStrength: 0.2)

    /// The jewel of a row's colour (`NowRow.tint`).
    static func of(_ tint: NightWatch.RGBA?) -> NWJewel {
        switch tint {
        case NightWatch.Palette.red?: return .red
        case NightWatch.Palette.sky?: return .sky
        case NightWatch.Palette.green?: return .green
        default: return .amber
        }
    }
}

/// A jewel's surface: its ramp, the light in its top corner, a bright lip, a
/// rim in its own light and a glow of that light under it. Opaque.
struct NWJewelSurface: View {
    var jewel: NWJewel
    var radius: CGFloat = NightWatch.Radius.card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [jewel.top.color, jewel.bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [jewel.light.opacity(jewel.lightStrength).color, jewel.light.opacity(0).color],
                                      center: .topLeading, startRadius: 0, endRadius: 300))
            shape.strokeBorder(LinearGradient(colors: [jewel.light.opacity(0.85).color, jewel.light.opacity(0.22).color],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // The lip: light catching the top edge.
            shape.strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(0.42), location: 0),
                                                      .init(color: Color.white.opacity(0), location: 0.3)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .shadow(color: jewel.light.opacity(0.26).color, radius: 18, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 2)
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

/// Information in the sky (the Runway): faint glass that sits back, with no
/// light and no shadow. It is read, not acted on.
struct NWSkyGlass: View {
    var radius: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.035))
            shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
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
    /// The tint of the chrome's glass: the page's own near-black, deep enough
    /// that white labels hold over the brightest sky of the day (the
    /// afternoon, and needs-you's amber at full strength).
    static let chromeGlass = NightWatch.RGBA(hex: 0x04060A, alpha: 0.6)
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
