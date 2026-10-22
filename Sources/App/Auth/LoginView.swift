import SwiftUI

// MARK: - 登录页
//
// ★ 文案规矩（他 10-22 定的）：只说「点一下会发生什么」，不写内部机制。
//   所以这里不出现「账号体系」「鉴权」「token」这些词。

struct LoginView: View {
    @ObservedObject private var auth = StillAuth.shared

    @State private var phone = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegister = false
    @FocusState private var focus: Field?

    private enum Field { case phone, password, name }

    private var canGo: Bool {
        phone.trimmingCharacters(in: .whitespaces).count == 11
            && password.count >= 6
            && !auth.busy
    }

    var body: some View {
        ZStack {
            Cfg.Palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    card
                    footer
                }
                .padding(.horizontal, 26)
                .padding(.top, 64)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focus = .phone }
    }

    // MARK: 上半截

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRegister ? "给自己开一个号" : "登录")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Cfg.Palette.ink)

            Text("每个号有自己的猫、自己的存档。\n别人登他的号，看不到你这只。")
                .font(.system(size: 13))
                .foregroundStyle(Cfg.Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 26)
    }

    // MARK: 中间那块

    private var card: some View {
        VStack(spacing: 14) {
            field(title: "手机号", text: $phone, focus: .phone,
                  keyboard: .numberPad, placeholder: "11 位手机号")

            field(title: "密码", text: $password, focus: .password,
                  keyboard: .default, placeholder: "至少 6 位", secure: true)

            if isRegister {
                field(title: "它叫你什么（可不填）", text: $name, focus: .name,
                      keyboard: .default, placeholder: "比如：我")
            }

            if !auth.error.isEmpty {
                Text(auth.error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.78, green: 0.22, blue: 0.19))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack {
                    Spacer()
                    if auth.busy {
                        ProgressView().tint(.white)
                    } else {
                        Text(isRegister ? "开号，进去" : "进去")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                }
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canGo ? Cfg.Palette.accent : Cfg.Palette.faint.opacity(0.35))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canGo)
            .padding(.top, 4)

            Button {
                auth.error = ""
                withAnimation(.easeInOut(duration: 0.18)) { isRegister.toggle() }
            } label: {
                Text(isRegister ? "已经有号了，去登录" : "还没号？开一个")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Cfg.Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Cfg.Palette.faint.opacity(0.22), lineWidth: 1)
        )
    }

    private func field(title: String, text: Binding<String>, focus f: Field,
                       keyboard: UIKeyboardType, placeholder: String,
                       secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Cfg.Palette.faint)

            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(Cfg.Palette.ink)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: f)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Cfg.Palette.bg)
            )
        }
    }

    // MARK: 下半截

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 18)
            Text("手机号和密码只用来认人，密码在你手机这边一个字都不存。")
                .font(.system(size: 11))
                .foregroundStyle(Cfg.Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        focus = nil
        let p = phone.trimmingCharacters(in: .whitespaces)
        Task {
            if isRegister {
                await auth.register(phone: p, password: password,
                                    name: name.trimmingCharacters(in: .whitespaces))
            } else {
                await auth.login(phone: p, password: password)
            }
        }
    }
}
