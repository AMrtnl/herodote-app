import SwiftUI
import UniformTypeIdentifiers

// MARK: - VaultSettingsView (vault location + WebDAV server)

struct VaultSettingsView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(SyncCenter.self) private var sync
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showFolderPicker = false
    @State private var errorMessage: String?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Emplacement", value: vault.locationName)
                LabeledContent("Notes", value: "\(vault.notes.count)")
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Choisir un autre dossier…", systemImage: "folder.badge.gearshape")
                }
                if vault.isExternal {
                    Button {
                        do { try vault.useLocalFolder() } catch { errorMessage = error.localizedDescription }
                    } label: {
                        Label("Revenir au coffre sur cet appareil", systemImage: "internaldrive")
                    }
                }
            } header: {
                Text("Coffre")
            } footer: {
                Text("Le coffre est un dossier de fichiers Markdown, compatible avec Obsidian. Placez-le dans iCloud Drive, Nextcloud, Synology Drive, Working Copy (Git) ou Möbius Sync (Syncthing) pour le retrouver sur vos autres appareils et sur votre serveur. Si le dossier choisi est vide, le coffre actuel y est copié.")
            }

            Section {
                TextField("https://cloud.exemple.fr/remote.php/dav/files/vous/Coffre", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Identifiant", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(sync.isConfigured ? "Mot de passe (inchangé si vide)" : "Mot de passe ou mot de passe d’application", text: $password)
                Button {
                    connect()
                } label: {
                    Label(sync.isConfigured ? "Enregistrer et synchroniser" : "Connecter et synchroniser",
                          systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(server.isEmpty || username.isEmpty || (!sync.isConfigured && password.isEmpty) || sync.isSyncing)
            } header: {
                Text("Serveur WebDAV")
            } footer: {
                Text("Fonctionne avec Nextcloud, ownCloud, Synology, QNAP, Apache ou nginx (WebDAV) et rclone serve. La synchronisation est bidirectionnelle : en cas de modification des deux côtés, les deux versions sont conservées. Le mot de passe est stocké dans le trousseau de l’appareil.")
            }

            if sync.isConfigured {
                Section("Synchronisation") {
                    Toggle("Synchroniser automatiquement", isOn: Binding(get: { sync.autoSync }, set: { sync.setAutoSync($0) }))
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Label("Synchroniser maintenant", systemImage: "arrow.clockwise")
                            Spacer()
                            if sync.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(sync.isSyncing)
                    if let date = sync.lastSync {
                        LabeledContent("Dernière synchronisation", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let message = sync.lastMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = sync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Déconnecter le serveur", role: .destructive) { confirmDisconnect = true }
                }
            }

            Section("Ouvrir dans Obsidian") {
                Text("Sur iPad ou Mac, ouvrez le même dossier comme coffre dans Obsidian : vos notes, vos projets d’écriture et les pages de vos carnets manuscrits (images et texte reconnu, dans le dossier Carnets) y apparaissent. Les liens « Ouvrir dans Carnets » ramènent au carnet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Coffre et serveur")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do { try vault.useExternalFolder(url) } catch { errorMessage = error.localizedDescription }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Coffre", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Déconnecter le serveur ?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Déconnecter", role: .destructive) { sync.disconnect() }
        } message: {
            Text("Vos fichiers restent sur l’appareil et sur le serveur.")
        }
        .onAppear {
            server = sync.account?.serverURL ?? ""
            username = sync.account?.username ?? ""
        }
    }

    private func connect() {
        let existing = sync.account.flatMap { Keychain.password(account: $0.keychainAccount) } ?? ""
        sync.configure(serverURL: server, username: username, password: password.isEmpty ? existing : password)
        password = ""
        Task { await sync.syncNow() }
    }
}
