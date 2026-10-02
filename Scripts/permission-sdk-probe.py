#!/usr/bin/env python3
"""Asks the SDKs which permission APIs exist on which platform.

Each probe is a few lines of Swift that use one API. It is type-checked against the SDK of each
platform, at the package's minimum deployment version, and the compiler's answer is sorted:

    yes          the code compiles at the minimum version
    <OS> N+      the API exists but is newer than the minimum: "only available in <OS> N or newer"
    no           the API is marked unavailable on the platform
    absent       the SDK does not declare the symbol or module for the platform
    ?            anything else; the first line of the error is kept

Run from the package root, with kind names as arguments to probe only those. Prints a Markdown table per kind, and then where each Info.plist key
is mentioned in the SDK headers, so that a key written down from memory can be told from one the SDK
confirms.
"""

import os
import re
import subprocess
import sys
import tempfile

PLATFORMS = [
    ("iOS", "iphonesimulator", "arm64-apple-ios16.0-simulator"),
    ("tvOS", "appletvsimulator", "arm64-apple-tvos16.0-simulator"),
    ("macOS", "macosx", "arm64-apple-macos14.0"),
    ("Catalyst", "macosx", "arm64-apple-ios16.0-macabi"),
]

# kind -> (framework imports, [(what the probe shows, async?, code)])
PROBES = {
    "camera": ("import AVFoundation", [
        ("status of video", False, "_ = AVCaptureDevice.authorizationStatus(for: .video)"),
        ("request, callback", False, "AVCaptureDevice.requestAccess(for: .video) { _ in }"),
        ("request, async", True, "_ = await AVCaptureDevice.requestAccess(for: .video)"),
        ("status .restricted", False, "_ = AVAuthorizationStatus.restricted"),
    ]),
    "microphone": ("import AVFoundation", [
        ("status of audio (capture device)", False, "_ = AVCaptureDevice.authorizationStatus(for: .audio)"),
        ("record permission (AVAudioApplication)", False, "_ = AVAudioApplication.shared.recordPermission"),
        ("request (AVAudioApplication)", False, "AVAudioApplication.requestRecordPermission { _ in }"),
        ("record permission (AVAudioSession)", False, "_ = AVAudioSession.sharedInstance().recordPermission"),
    ]),
    "photos": ("import Photos", [
        ("status read and write", False, "_ = PHPhotoLibrary.authorizationStatus(for: .readWrite)"),
        ("status add only", False, "_ = PHPhotoLibrary.authorizationStatus(for: .addOnly)"),
        ("request", False, "PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }"),
        ("status .limited", False, "_ = PHAuthorizationStatus.limited"),
    ]),
    "notifications": ("import UserNotifications", [
        ("settings, async", True, "_ = await UNUserNotificationCenter.current().notificationSettings()"),
        ("request, async", True, "_ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])"),
        ("option .provisional", False, "_ = UNAuthorizationOptions.provisional"),
        ("status .ephemeral", False, "_ = UNAuthorizationStatus.ephemeral"),
        ("option .criticalAlert", False, "_ = UNAuthorizationOptions.criticalAlert"),
    ]),
    "location": ("import CoreLocation", [
        ("status (instance)", False, "_ = CLLocationManager().authorizationStatus"),
        ("request when in use", False, "CLLocationManager().requestWhenInUseAuthorization()"),
        ("request always", False, "CLLocationManager().requestAlwaysAuthorization()"),
        ("accuracy authorization", False, "_ = CLLocationManager().accuracyAuthorization"),
        ("temporary full accuracy", False, "CLLocationManager().requestTemporaryFullAccuracyAuthorization(withPurposeKey: \"k\") { _ in }"),
        ("services enabled", False, "_ = CLLocationManager.locationServicesEnabled()"),
        ("status .authorizedAlways", False, "_ = CLAuthorizationStatus.authorizedAlways"),
    ]),
    "contacts": ("import Contacts", [
        ("status", False, "_ = CNContactStore.authorizationStatus(for: .contacts)"),
        ("request", False, "CNContactStore().requestAccess(for: .contacts) { _, _ in }"),
        ("status .limited", False, "_ = CNAuthorizationStatus.limited"),
    ]),
    "calendar": ("import EventKit", [
        ("status of events", False, "_ = EKEventStore.authorizationStatus(for: .event)"),
        ("request full access", False, "EKEventStore().requestFullAccessToEvents { _, _ in }"),
        ("request write only", False, "EKEventStore().requestWriteOnlyAccessToEvents { _, _ in }"),
        ("status .writeOnly", False, "_ = EKAuthorizationStatus.writeOnly"),
    ]),
    "reminders": ("import EventKit", [
        ("status of reminders", False, "_ = EKEventStore.authorizationStatus(for: .reminder)"),
        ("request full access", False, "EKEventStore().requestFullAccessToReminders { _, _ in }"),
    ]),
    "bluetooth": ("import CoreBluetooth", [
        ("status (class property)", False, "_ = CBManager.authorization"),
        ("status .restricted", False, "_ = CBManagerAuthorization.restricted"),
    ]),
    "speech": ("import Speech", [
        ("status", False, "_ = SFSpeechRecognizer.authorizationStatus()"),
        ("request", False, "SFSpeechRecognizer.requestAuthorization { _ in }"),
    ]),
    "tracking": ("import AppTrackingTransparency", [
        ("status", False, "_ = ATTrackingManager.trackingAuthorizationStatus"),
        ("request", False, "ATTrackingManager.requestTrackingAuthorization { _ in }"),
    ]),
    "motion": ("import CoreMotion", [
        ("status (activity)", False, "_ = CMMotionActivityManager.authorizationStatus()"),
        ("status (pedometer)", False, "_ = CMPedometer.authorizationStatus()"),
        ("status (altimeter)", False, "_ = CMAltimeter.authorizationStatus()"),
    ]),
    "media library": ("import MediaPlayer", [
        ("status", False, "_ = MPMediaLibrary.authorizationStatus()"),
        ("request", False, "MPMediaLibrary.requestAuthorization { _ in }"),
    ]),
    "local network": ("import Network", [
        ("browser exists", False, "_ = NWBrowser.self"),
    ]),
    "settings": ("import Foundation\n#if canImport(UIKit)\nimport UIKit\n#endif", [
        ("open-settings URL string (UIKit)", False, "_ = UIApplication.openSettingsURLString"),
        ("open-notification-settings URL string (UIKit)", False, "_ = UIApplication.openNotificationSettingsURLString"),
    ]),
}

# key -> frameworks whose headers are searched
KEYS = {
    "NSCameraUsageDescription": ["AVFoundation", "AVFCapture"],
    "NSMicrophoneUsageDescription": ["AVFoundation", "AVFAudio"],
    "NSPhotoLibraryUsageDescription": ["Photos"],
    "NSPhotoLibraryAddUsageDescription": ["Photos"],
    "NSLocationWhenInUseUsageDescription": ["CoreLocation"],
    "NSLocationAlwaysAndWhenInUseUsageDescription": ["CoreLocation"],
    "NSLocationTemporaryUsageDescriptionDictionary": ["CoreLocation"],
    "NSContactsUsageDescription": ["Contacts"],
    "NSCalendarsUsageDescription": ["EventKit"],
    "NSCalendarsFullAccessUsageDescription": ["EventKit"],
    "NSCalendarsWriteOnlyAccessUsageDescription": ["EventKit"],
    "NSRemindersUsageDescription": ["EventKit"],
    "NSRemindersFullAccessUsageDescription": ["EventKit"],
    "NSBluetoothAlwaysUsageDescription": ["CoreBluetooth"],
    "NSSpeechRecognitionUsageDescription": ["Speech"],
    "NSUserTrackingUsageDescription": ["AppTrackingTransparency"],
    "NSMotionUsageDescription": ["CoreMotion"],
    "NSAppleMusicUsageDescription": ["MediaPlayer"],
    "NSLocalNetworkUsageDescription": ["Network"],
    "NSBonjourServices": ["Network"],
}


def sdk_path(sdk):
    return subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()


def sdk_version(sdk):
    return subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True).strip()


def classify(output):
    errors = [line for line in output.splitlines() if "error:" in line]
    if not errors:
        return "yes"
    text = " ".join(errors)
    match = re.search(r"only available in (\w+(?: \w+)?) ([\d.]+)", text)
    if match:
        return f"{match.group(2)}+"
    if "is unavailable in" in text or "unavailable" in text and "not available" not in text:
        return "no"
    if "no such module" in text or "cannot find" in text or "has no member" in text or "undefined" in text:
        return "absent"
    return "? " + errors[0].split("error:", 1)[1].strip()[:70]


def probe(sdk, target, imports, is_async, code):
    body = ("func probe() async throws {\n" if is_async else "func probe() {\n") + "    " + code + "\n}\n"
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as handle:
        handle.write(imports + "\n" + body)
        path = handle.name
    try:
        command = ["xcrun", "--sdk", sdk, "swiftc", "-typecheck", "-target", target]
        if target.endswith("macabi"):
            # Catalyst frameworks that exist only for it, UIKit among them, live in iOSSupport.
            command += ["-Fsystem", f"{sdk_path(sdk)}/System/iOSSupport/System/Library/Frameworks"]
        result = subprocess.run(command + [path], capture_output=True, text=True)
        return classify(result.stdout + result.stderr)
    finally:
        os.unlink(path)


def main():
    print("SDKs:", ", ".join(f"{sdk} {sdk_version(sdk)}" for sdk in sorted({p[1] for p in PLATFORMS})))
    print("Minimum versions probed: iOS 16, tvOS 16, macOS 14, Catalyst (iOS 16 macabi)\n")
    wanted = sys.argv[1:]
    for kind, (imports, items) in PROBES.items():
        if wanted and kind not in wanted:
            continue
        print(f"### {kind}\n")
        print("| API | " + " | ".join(p[0] for p in PLATFORMS) + " |")
        print("|---|" + "---|" * len(PLATFORMS))
        for what, is_async, code in items:
            cells = [probe(sdk, target, imports, is_async, code) for _, sdk, target in PLATFORMS]
            print(f"| {what} | " + " | ".join(cells) + " |")
        print()

    if wanted:
        return
    print("### Info.plist keys found in SDK headers\n")
    print("| Key | iOS | tvOS | macOS |")
    print("|---|---|---|---|")
    roots = {"iOS": sdk_path("iphonesimulator"), "tvOS": sdk_path("appletvsimulator"), "macOS": sdk_path("macosx")}
    for key, frameworks in KEYS.items():
        cells = []
        for name, root in roots.items():
            found = False
            for framework in frameworks:
                for base in (f"{root}/System/Library/Frameworks", f"{root}/System/Library/PrivateFrameworks"):
                    for directory in subprocess.run(
                        ["find", base, "-maxdepth", "1", "-name", f"{framework}*.framework"],
                        capture_output=True, text=True,
                    ).stdout.split():
                        grep = subprocess.run(
                            ["grep", "-rl", "--include=*.h", key, directory],
                            capture_output=True, text=True,
                        )
                        if grep.stdout.strip():
                            found = True
            cells.append("yes" if found else "-")
        print(f"| {key} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    sys.exit(main())
