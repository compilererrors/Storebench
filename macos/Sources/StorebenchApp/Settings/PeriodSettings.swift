import AppKit
import StorebenchCore
import SwiftUI

struct PeriodSettings: View {
    let model: LibraryModel
    @State private var baseline: PeriodPreferences?
    @State private var remember = true
    @State private var compare = 7
    @State private var download = 7
    @State private var sync = 30
    @State private var range = PeriodRangeChoice.all
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    private var changed: Bool { baseline.map { $0.remember != remember || $0.compareDays != compare || $0.downloadDays != download || $0.syncReach != sync || $0.defaultRange != range } ?? false }
    var body: some View {
        StorebenchForm {
            StorebenchFormSection("Periods") {
                if baseline == nil || model.session == nil {
                    StorebenchLoadState(state: model.session == nil ? .failed("Open a workspace to change period preferences.", retry: { await load() })
                        : working || status.isEmpty ? .loading("Reading period preferences…") : .failed(status, retry: { await load() })) { EmptyView() }
                } else {
                Toggle("Remember my last period choice in each view", isOn: $remember)
                Text("Sales, Analytics, Finance and ASO views open with their remembered choices or these defaults.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                PeriodRangeField(choice: $range, latest: PeriodDates.text(Date()), title: "Default dates shown")
                PeriodDaysField(title: "Default comparison window", value: $compare)
                PeriodDaysField(title: "Default download period", value: $download)
                PeriodDaysField(title: "Sync history", value: $sync)
                Text("Sync fills report history from this reach. Latest date ranges follow the newest saved report; custom ranges retain exact dates.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                Text("\(baseline?.rememberedCount ?? 0) views remember an earlier choice.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                Text(status.isEmpty ? changed ? "Unsaved period change. Choose Save Period Defaults to keep it." : "Period preferences are saved." : status)
                    .font(.sbCallout).foregroundStyle(problem ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                StorebenchFormFooter {
                    Button("Save Period Defaults") { Task { await save() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!changed)
                    Button("Forget Choices") { Task { await forget() } }.storebenchWorking(baseline?.rememberedCount == 0).help("Forget Remembered Choices").accessibilityLabel("Forget Remembered Choices")
                }
                }
            }
        }.storebenchWorking(working)
            .trackUnsavedChanges(changed, busy: working, problem: { problem ? "Period defaults: " + status : nil }, onSave: { await save(); return !changed })
            .task { await load() }
    }
    private func load() async {
        guard !working, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            let saved = try await session.periodPreferences(); try Task.checkCancellation()
            baseline = saved; remember = saved.remember; compare = saved.compareDays; download = saved.downloadDays; sync = saved.syncReach; range = saved.defaultRange; status = ""
        } catch { status = "Period preferences could not be read. Your saved defaults are unchanged." }
    }
    private func save() async {
        guard !working, baseline != nil, changed, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            baseline = try await session.savePeriodDefaults(remember: remember, compareDays: compare, downloadDays: download, range: range, syncDays: sync)
            problem = false; status = remember ? "Defaults saved. Views reopen with your last choice." : "Defaults saved. Earlier choices are forgotten."
        } catch { problem = true; status = "Period defaults were not saved. Your inputs remain here; try again." }
    }
    private func forget() async {
        guard !working, baseline != nil, let session = model.session else { return }
        working = true; defer { working = false }
        do { baseline = try await session.forgetPeriods(); status = "Remembered choices cleared. Your default edits remain here until saved." }
        catch { status = "Remembered choices could not be cleared." }
    }
}
