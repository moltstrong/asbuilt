import SwiftUI
import AsBuiltCore

struct JobListView: View {
    @EnvironmentObject private var store: JobStore
    @EnvironmentObject private var router: Router
    @State private var showingNewJob = false

    private var realJobs: [Job] { store.jobs.filter { !$0.isDemo } }
    private var demoJobs: [Job] { store.jobs.filter { $0.isDemo } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Button {
                    showingNewJob = true
                } label: {
                    Label("New job site", systemImage: "plus.circle.fill")
                }
                .buttonStyle(BigButtonStyle())
                .accessibilityIdentifier("newJobButton")

                if !realJobs.isEmpty {
                    SectionHeader(title: "Job sites", systemImage: "building.2")
                    ForEach(realJobs) { job in
                        NavigationLink(value: Route.job(job.id)) { JobRow(job: job) }
                            .buttonStyle(.plain)
                    }
                } else {
                    emptyState
                }

                if !demoJobs.isEmpty {
                    SectionHeader(title: "Demo", systemImage: "play.rectangle")
                    ForEach(demoJobs) { job in
                        NavigationLink(value: Route.job(job.id)) { JobRow(job: job) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("demoJobRow")
                    }
                    DemoStatusLine()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("AsBuilt")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: Route.capabilities) {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Device capabilities")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingNewJob) {
            JobEditorView(job: nil) { job in
                router.path.append(.job(job.id))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent)
                Image(systemName: "ruler")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan it. Measure it. Send it.")
                    .font(.headline)
                Text("LiDAR room scans and 3D object captures, exported as DXF, USDZ, PDF and CSV takeoffs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No job sites yet").font(.headline)
            Text("Create a job for each site, then scan rooms and capture equipment, fixtures or damage. Open the Demo job to see a finished example.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}

/// "Preparing demo…" while the demo files are generated after launch, or a non-fatal notice.
struct DemoStatusLine: View {
    @EnvironmentObject private var store: JobStore

    var body: some View {
        if store.demoStatus == .preparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing demo…").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("demoPreparing")
        } else if let notice = store.demoNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("demoNotice")
        } else if case .failed(let message) = store.demoStatus {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.isDemo ? "house.lodge" : "building.2.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(job.name).font(.headline).lineLimit(2)
                    if job.isDemo { Badge(text: "DEMO") }
                }
                if !job.address.isEmpty {
                    Label(job.address, systemImage: "mappin.and.ellipse")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !job.client.isEmpty {
                    Label(job.client, systemImage: "person")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Label(Self.countsText(rooms: job.roomCaptures.count, objects: job.objectCaptures.count),
                      systemImage: "square.split.bottomrightquarter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 72)
        .card()
        .contentShape(Rectangle())
    }

    static func countsText(rooms: Int, objects: Int) -> String {
        "\(rooms) \(rooms == 1 ? "room" : "rooms") · \(objects) \(objects == 1 ? "object" : "objects")"
    }
}

struct JobEditorView: View {
    let job: Job?
    var onSaved: (Job) -> Void = { _ in }

    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var client = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Job site") {
                    TextField("Job name (e.g. Smith kitchen remodel)", text: $name)
                        .font(.title3)
                        .frame(minHeight: 44)
                    TextField("Site address", text: $address)
                        .textContentType(.fullStreetAddress)
                        .frame(minHeight: 44)
                    TextField("Client", text: $client)
                        .frame(minHeight: 44)
                }
                Section("Notes") {
                    TextField("Access, scope, contacts…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(job == nil ? "New job" : "Edit job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.bold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let job {
                    name = job.name
                    address = job.address
                    client = job.client
                    notes = job.notes
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var existing = job {
            existing.name = trimmed
            existing.address = address
            existing.client = client
            existing.notes = notes
            store.save(existing)
            onSaved(existing)
        } else {
            let created = store.createJob(name: trimmed, address: address, client: client, notes: notes)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onSaved(created) }
            return
        }
        dismiss()
    }
}
