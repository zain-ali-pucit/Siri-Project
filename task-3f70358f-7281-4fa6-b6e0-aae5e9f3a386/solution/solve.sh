#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
LOGS_ROOT="${LOGS_ROOT:-/logs}"
cd "$WORKSPACE"

patch -p1 --forward <<'PATCH'
--- a/flo/Navigation/PreferencesView.swift
+++ b/flo/Navigation/PreferencesView.swift
@@ -93,6 +93,8 @@
   @State private var playerColor = Color(.player)
   @State private var customFontFamily = "Plus Jakarta Sans"
   @AppStorage(UserDefaultsKeys.uiFontScale) private var uiFontScale: Double = 1.0
+  @AppStorage(UserDefaultsKeys.enableDebug) private var enableDebug = false
+  @AppStorage(UserDefaultsKeys.libraryViewV2) private var libraryViewV2 = false
 
   @EnvironmentObject var floooViewModel: FloooViewModel
   @EnvironmentObject var playerViewModel: PlayerViewModel
@@ -167,6 +169,14 @@
     return "000000"
   }
 
+  private func resetExperimentalSettings() {
+    enableDebug = false
+    libraryViewV2 = false
+    experimentalMaxBitrate = TranscodingSettings.sourceBitRate
+    UserDefaultsManager.maxBitRate = TranscodingSettings.sourceBitRate
+    APIManager.shared.reconfigureSession()
+  }
+
   private var mainContent: some View {
     NavigationStack {
       Form {
@@ -342,12 +352,13 @@
             Toggle(
               "Enable Debug",
               isOn: Binding(
-                get: { UserDefaultsManager.enableDebug },
+                get: { enableDebug },
                 set: { value in
-                  UserDefaultsManager.enableDebug = value
+                  enableDebug = value
                   APIManager.shared.reconfigureSession()
                 }
               ))
+              .accessibilityIdentifier("enableDebugToggle")
 
             Text(
               "Enabling this option may affect the experience."
@@ -386,6 +397,7 @@
             .onChange(of: experimentalMaxBitrate) { value in
               UserDefaultsManager.maxBitRate = value
             }
+            .accessibilityIdentifier("maxBitratePicker")
 
             Text(
               "Currently the output format is MP3 due to compatibility issues; however, MP3 is less efficient in streaming at lower bitrates compared to modern codecs like Opus."
@@ -441,16 +453,17 @@
           }
 
           VStack(alignment: .leading, spacing: 4) {
-            Toggle(
-              "Library View V2",
-              isOn: Binding(
-                get: { UserDefaultsManager.libraryViewV2 },
-                set: { UserDefaultsManager.libraryViewV2 = $0 }
-              ))
+            Toggle("Library View V2", isOn: $libraryViewV2)
+              .accessibilityIdentifier("libraryViewV2Toggle")
 
             Text("Unified library").font(.caption)
               .foregroundColor(.gray)
           }
+
+          Button(role: .destructive, action: resetExperimentalSettings) {
+            Text("Reset experimental settings")
+          }
+          .accessibilityIdentifier("resetExperimentalButton")
         }
 
         Section(header: Text("Development")) {
PATCH
