import SwiftUI

// MARK: - 一枚小组件
//
// 这些不是真的小组件，是 App 内画布上画出来的、长得跟 iOS 小组件一样的东西。
// 真小组件（WidgetKit）在 Sources/Widget 里 —— 那边是系统渲染的静态快照，
// 动不了，也没法配合演出「它从 A 走到 B」。

struct WidgetCardView: View {

    let room: Room
    var visited: Bool = false
    var isHere: Bool = false
    var shaking: Bool = false
    var onTap: (() -> Void)? = nil

    private var tint: Color { Color(hex: room.tintHex) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 底：iOS 小组件那种微微的渐变
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), tint.opacity(0.30)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.55))
                )

            content

            // 留痕：它来过，角落里就有一枚淡淡的爪印
            if visited {
                PawMark(color: tint)
                    .frame(width: 15, height: 15)
                    .opacity(0.34)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            // 它现在就在这儿
            if isHere {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Cfg.Palette.accent.opacity(0.55), lineWidth: 1.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 9, x: 0, y: 3)
        .offset(x: shaking ? shakeOffset : 0, y: shaking ? shakeOffset * 0.6 : 0)
        .animation(shaking ? .easeInOut(duration: 0.09).repeatCount(5, autoreverses: true) : .default,
                   value: shaking)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private var shakeOffset: CGFloat { 3.2 }

    // MARK: 16 种内容

    @ViewBuilder
    private var content: some View {
        switch room.kind {
        case .still:   stillBody
        case .clock:   clockBody
        case .weather: weatherBody
        case .photo:   photoBody
        case .notes:   notesBody
        case .music:   musicBody
        case .podcast: podcastBody
        case .cal:     calBody
        case .remind:  remindBody
        case .health:  healthBody
        case .maps:    mapsBody
        case .album:   albumBody
        case .battery: batteryBody
        case .short:   shortBody
        case .world:   worldBody
        case .timer:   timerBody
        }
    }

    private var stillBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("它现在在").font(.system(size: 9)).foregroundStyle(Cfg.Palette.faint)
            Text("—").font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(Cfg.Palette.ink)
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clockBody: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.32), lineWidth: 1.6)
                .frame(width: 58, height: 58)
            Capsule().fill(tint).frame(width: 1.8, height: 17).offset(y: -8)
            Capsule().fill(tint).frame(width: 1.5, height: 13)
                .offset(x: 7, y: 4).rotationEffect(.degrees(52))
            Capsule().fill(Cfg.Palette.accent).frame(width: 1, height: 20)
                .offset(x: -5, y: 9).rotationEffect(.degrees(130))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weatherBody: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("北京").font(.system(size: 9)).foregroundStyle(tint.opacity(0.85))
                Text("24°").font(.system(size: 21, design: .serif))
                Text("多云 转晴").font(.system(size: 8)).foregroundStyle(tint.opacity(0.8))
            }
            Spacer()
            ZStack {
                Circle().fill(Color(hex: 0xEFC97A)).frame(width: 19, height: 19).offset(x: 7, y: -5)
                CloudShape().fill(.white.opacity(0.92)).frame(width: 30, height: 16).offset(y: 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoBody: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hex: 0xF6D9C0), Color(hex: 0xDDB69A)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color(hex: 0xB08A5E)).frame(height: 42).opacity(0.85)
            Circle().fill(Color(hex: 0xF3E3D2)).frame(width: 26, height: 26).offset(y: -6)
        }
        .padding(7)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var notesBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<4) { i in
                Capsule().fill(tint.opacity(i == 3 ? 0.28 : 0.45))
                    .frame(height: 3)
                    .frame(width: i == 3 ? 34 : nil)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var musicBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.4))
                .frame(width: 30, height: 30)
            // 波形高度写死 —— 用随机值的话每次重绘都会抖一下，看着像坏了
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(WaveHeights.heights, id: \.self) { h in
                    Capsule().fill(tint.opacity(0.6)).frame(width: 2.4, height: h)
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var podcastBody: some View {
        VStack(spacing: 6) {
            Circle().fill(tint.opacity(0.38)).frame(width: 30, height: 30)
            Capsule().fill(tint.opacity(0.35)).frame(height: 5)
            Capsule().fill(tint.opacity(0.25)).frame(width: 40, height: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("3").font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(tint)
            Text("周四").font(.system(size: 9)).foregroundStyle(tint.opacity(0.8))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 5), spacing: 3) {
                ForEach(0..<10) { i in
                    Circle().fill(i == 2 ? tint : tint.opacity(0.22)).frame(height: 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remindBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3) { i in
                HStack(spacing: 6) {
                    Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1.2)
                        .frame(width: 10, height: 10)
                    Capsule().fill(tint.opacity(0.4)).frame(height: 3)
                }
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthBody: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .trim(from: 0, to: 0.72 - Double(i) * 0.18)
                    .stroke(tint.opacity(0.7 - Double(i) * 0.16),
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 40 - CGFloat(i) * 11, height: 40 - CGFloat(i) * 11)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapsBody: some View {
        ZStack {
            Rectangle().fill(Color(hex: 0xCEE0D3))
            Path { p in
                p.move(to: CGPoint(x: 0, y: 34)); p.addLine(to: CGPoint(x: 100, y: 20))
                p.move(to: CGPoint(x: 30, y: 0)); p.addLine(to: CGPoint(x: 22, y: 100))
                p.move(to: CGPoint(x: 0, y: 62)); p.addLine(to: CGPoint(x: 100, y: 74))
            }
            .stroke(.white, lineWidth: 3.5)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 34)); p.addLine(to: CGPoint(x: 100, y: 20))
            }
            .stroke(Color(hex: 0xF5C15E), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var albumBody: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.22 + Double(i) * 0.13))
                    .overlay(
                        Circle().fill(.white.opacity(0.5)).frame(width: 14, height: 14)
                    )
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batteryBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("82%").font(.system(size: 16, weight: .medium, design: .serif))
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2)).frame(height: 9)
                Capsule().fill(tint.opacity(0.75)).frame(width: 52, height: 9)
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortBody: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 2), spacing: 5) {
            ForEach(0..<4) { _ in
                RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.32)).aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var worldBody: some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                MiniClock(color: tint, hourAngle: 0.6)
                Text("北京").font(.system(size: 7)).foregroundStyle(tint.opacity(0.8))
            }
            VStack(spacing: 3) {
                MiniClock(color: tint, hourAngle: 2.4)
                Text("纽约").font(.system(size: 7)).foregroundStyle(tint.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timerBody: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.22), lineWidth: 3.5).frame(width: 42, height: 42)
            Circle().trim(from: 0, to: 0.63)
                .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 42, height: 42)
            Text("12:40").font(.system(size: 9, design: .monospaced)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 零件

/// 音乐组件的波形高度（写死，别用随机数 —— 否则每次重绘都在抖）
enum WaveHeights {
    static let heights: [CGFloat] = [7, 13, 9, 15, 6, 11, 8]
}

struct MiniClock: View {
    var color: Color
    var hourAngle: Double
    var body: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(0.45), lineWidth: 1.1).frame(width: 22, height: 22)
            Capsule().fill(color).frame(width: 1, height: 6).offset(y: -3)
                .rotationEffect(.degrees(hourAngle * 30))
        }
    }
}

struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: 0, y: h))
        p.addQuadCurve(to: CGPoint(x: w * 0.2, y: 0), control: CGPoint(x: w * 0.04, y: h * 0.2))
        p.addQuadCurve(to: CGPoint(x: w * 0.47, y: h * 0.18), control: CGPoint(x: w * 0.3, y: -h * 0.28))
        p.addQuadCurve(to: CGPoint(x: w * 0.76, y: 0), control: CGPoint(x: w * 0.62, y: -h * 0.14))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w * 0.96, y: h * 0.1))
        p.closeSubpath()
        return p
    }
}

/// 爪印 —— 它来过的证据
struct PawMark: View {
    var color: Color = Cfg.Palette.accent

    var body: some View {
        ZStack {
            Ellipse().frame(width: 8.4, height: 7.2).offset(y: 2.6)
            Ellipse().frame(width: 6, height: 4.6).offset(y: 5.4)
            Group {
                Ellipse().frame(width: 3.2, height: 4).offset(x: -5.4, y: -2.4).rotationEffect(.degrees(-16))
                Ellipse().frame(width: 3.2, height: 4.2).offset(x: -1.8, y: -4.6).rotationEffect(.degrees(-6))
                Ellipse().frame(width: 3.2, height: 4.2).offset(x: 1.8, y: -4.6).rotationEffect(.degrees(6))
                Ellipse().frame(width: 3.2, height: 4).offset(x: 5.4, y: -2.4).rotationEffect(.degrees(16))
            }
        }
        .foregroundStyle(color)
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 12) {
        ForEach(Rooms.all.prefix(8)) { r in
            WidgetCardView(room: r, visited: true, isHere: r.id == "clock")
                .frame(height: 96)
        }
    }
    .padding()
    .background(Cfg.Palette.bg)
}
