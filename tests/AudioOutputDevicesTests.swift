// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Audio output devices")
    struct AudioOutputDevicesTests {
        @Test("a device that isn't there has no ID")
        func unknownDevice() {
            #expect(AudioOutputDevices.deviceID(forUID: "no-such-device-\(#line)") == nil)
            #expect(AudioOutputDevices.deviceID(forUID: "") == nil)
        }

        // What is connected depends on the machine, so only what holds for any list is checked.
        @Test("the listed devices have names and unique UIDs, and each UID is found again")
        func listedDevices() {
            let devices = AudioOutputDevices.all()
            #expect(Set(devices.map(\.uid)).count == devices.count)
            for device in devices {
                #expect(!device.name.isEmpty)
                #expect(AudioOutputDevices.deviceID(forUID: device.uid) != nil)
            }
        }
    }
}
