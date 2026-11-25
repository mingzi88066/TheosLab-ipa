//
// NewProjectView.swift
// Theos Lab
//
// Collects what nic.pl would ask for, then hands the answers to the console so
// the generation happens on a real pty and stays visible.
//

import SwiftUI
import Foundation

struct NewProjectView: View {
    struct Template: Identifiable, Hashable {
        let id: String
        let title: String
        let note: String
        var isTweak: Bool { id.contains("tweak") }
    }

    static let templates: [Template] = [
        .init(id: "iphone/tweak", title: "Tweak", note: "注入 SpringBoard 等进程（最常用）"),
        .init(id: "iphone/tweak_with_simple_preferences", title: "Tweak + 设置面板", note: "带 Preference Bundle 的 Tweak"),
        .init(id: "iphone/control_center_module-11up", title: "控制中心模块", note: "CC 模块，iOS 11 以上"),
        .init(id: "iphone/application_modern", title: "应用（ObjC）", note: "独立 App，Objective-C"),
        .init(id: "iphone/application_swiftui", title: "应用（SwiftUI）", note: "独立 App，Swift + SwiftUI"),
        .init(id: "iphone/preference_bundle", title: "设置面板", note: "只做设置界面，供 Tweak 引用"),
        .init(id: "iphone/library", title: "动态库", note: "普通 dylib"),
        .init(id: "iphone/tool", title: "命令行工具", note: "无界面的可执行文件"),
        .init(id: "iphone/framework", title: "Framework", note: "可被其他项目链接")
    ]

    let create: (String, String, String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("nicAuthor") private var storedAuthor = ""
    @State private var template = NewProjectView.templates[0]
    @State private var name = "MyTweak"
    @State private var package = "com.yourcompany.mytweak"
    @State private var author = ""
    @State private var filter = "com.apple.springboard"
    @State private var terminate = "SpringBoard"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("模板", selection: $template) {
                        ForEach(Self.templates) { item in
                            Text("\(item.title) · \(item.note)").tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("项目类型")
                } footer: {
                    Text("对应 nic.pl 的 -t \(template.id)")
                }

                Section {
                    TextField("项目名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("包名", text: $package)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("用项目名") { package = "com.yourcompany." + Self.slug(name) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    TextField("作者 / 维护者", text: $author)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("基本信息")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("项目文件夹会创建在「我的 iPhone → Theos Lab → Projects」。")
                    }
                }

                if template.isTweak {
                    Section {
                        TextField("Bundle filter", text: $filter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("安装后结束的进程", text: $terminate)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("注入设置")
                    } footer: {
                        Text("多个进程用空格分隔；填 - 表示安装后不结束任何进程。")
                    }
                }

                Section {
                    Label("创建时会调用 $THEOS/bin/nic.pl，输出会实时显示在终端里。", systemImage: "terminal")
                        .font(.footnote)
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { submit() }
                        .disabled(problem != nil)
                }
            }
            .onAppear {
                if author.isEmpty {
                    author = storedAuthor.isEmpty
                        ? (NSFullUserName().isEmpty ? "Your Name" : NSFullUserName())
                        : storedAuthor
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var problem: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPackage = package.trimmingCharacters(in: .whitespaces)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        guard (1...40).contains(trimmedName.count),
              trimmedName.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return "项目名要以字母开头，只含字母、数字、下划线。"
        }
        guard trimmedPackage.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*$"#, options: .regularExpression) != nil,
              trimmedPackage.contains(".") else {
            return "包名要像 com.yourname.project，只能含字母、数字、点、连字符。"
        }
        guard !trimmedAuthor.isEmpty else { return "作者不能为空。" }
        return nil
    }

    private static func slug(_ value: String) -> String {
        let cleaned = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "project" : cleaned
    }

    private func submit() {
        guard problem == nil else { return }
        storedAuthor = author
        create(template.id,
               name.trimmingCharacters(in: .whitespaces),
               package.trimmingCharacters(in: .whitespaces),
               author.trimmingCharacters(in: .whitespaces),
               template.isTweak ? filter.trimmingCharacters(in: .whitespaces) : "",
               template.isTweak ? terminate.trimmingCharacters(in: .whitespaces) : "")
        dismiss()
    }
}
