//
// TerminalView.swift
// Theos Lab
//
// Console UI: monospaced transcript, a single input line, and chips for the
// commands people actually run while building a tweak.
//

import SwiftUI

struct TerminalView: View {
    @ObservedObject var model: TerminalModel
    let project: URL?
    let onNewProject: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var typing: Bool

    private struct Chip: Identifiable {
        let id: String
        let command: String
        let title: String
    }

    private let chips = [
        Chip(id: "package", command: "make package", title: "make package"),
        Chip(id: "clean", command: "make clean", title: "make clean"),
        Chip(id: "ls", command: "ls -l", title: "ls"),
        Chip(id: "pwd", command: "pwd", title: "pwd")
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                console
                Divider()
                chipRow
                Divider()
                inputBar
            }
            .navigationTitle("终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    actions
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            model.start()
            typing = true
        }
    }

    private var actions: some View {
        Menu {
            Button {
                onNewProject()
            } label: { Label("新建项目…", systemImage: "plus.square.on.square") }
            if let project {
                Button {
                    model.upload(project)
                } label: { Label("同步当前项目到 /root/work", systemImage: "arrow.up.doc") }
            }
            Divider()
            Button {
                model.interrupt()
            } label: { Label("中断", systemImage: "stop.circle") }
                .disabled(!model.running)
            Button {
                model.clear()
            } label: { Label("清屏", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.text.isEmpty ? " " : model.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .id("console-bottom")
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.08))
            .foregroundStyle(Color(red: 0.86, green: 0.88, blue: 0.9))
            .onChange(of: model.text) { _ in
                proxy.scrollTo("console-bottom", anchor: .bottom)
            }
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.running {
                    ProgressView().controlSize(.mini)
                }
                ForEach(chips) { chip in
                    Button(chip.title) { model.run(chip.command) }
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                        .buttonStyle(.plain)
                }
                Button {
                    onNewProject()
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("输入命令", text: $input)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($typing)
                .onSubmit { submit(input) }
                .accessibilityIdentifier("terminal-input")
            Button {
                input = model.previousCommand() ?? input
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.history.isEmpty)
            Button(action: { submit(input) }) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func submit(_ command: String) {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        model.run(clean)
        input = ""
    }
}
