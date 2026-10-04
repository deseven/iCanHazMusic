import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor
    private final class RecordingDelivery: NotificationDelivery {
        private(set) var delivered: [(message: NotificationMessage, cover: Data?)] = []

        func deliver(_ message: NotificationMessage, cover: Data?) {
            delivered.append((message, cover))
        }
    }

    @MainActor @Suite("Notifications")
    struct NotificationTests {
        private func makeService() throws -> (NotificationService, RecordingDelivery, CoverStore) {
            let dir = try TempDir()
            let covers = CoverStore(url: dir.path("covers.sqlite"), thumbnailPixels: 112)
            let delivery = RecordingDelivery()
            return (NotificationService(delivery: delivery, coverStore: covers), delivery, covers)
        }

        @Test("a track that starts is announced with its title, artist, album, duration and cover")
        func trackStart() throws {
            let (service, delivery, covers) = try makeService()
            let image = Data([0xFF, 0xD8, 0xFF, 0xE0])
            covers.store(image, for: "album-key")

            var track = LastFMTestData.track(artist: "Artist", title: "Title", album: "Album", duration: 185)
            track.coverKey = "album-key"
            service.trackDidStart(track)

            let sent = try #require(delivery.delivered.first)
            #expect(delivery.delivered.count == 1)
            #expect(sent.message == NotificationMessage(title: "Title", subtitle: "Artist", body: "Album · 3:05"))
            #expect(sent.cover == image)
        }

        @Test("a track without cover, album or duration says only what is known")
        func sparseTrack() throws {
            let (service, delivery, _) = try makeService()
            var track = LastFMTestData.track(album: TagFallback.album, duration: 0)
            track.coverKey = "nothing-cached"
            service.trackDidStart(track)

            let sent = try #require(delivery.delivered.first)
            #expect(sent.message.body.isEmpty)
            #expect(sent.cover == nil)
        }

        @Test("the end of the playlist is announced, the end of a track isn't")
        func playlistEnd() throws {
            let (service, delivery, _) = try makeService()
            service.trackDidEnd(LastFMTestData.track(), playedSeconds: 100)
            #expect(delivery.delivered.isEmpty)

            service.playlistDidEnd(playlist: "Road trip")
            let sent = try #require(delivery.delivered.first)
            #expect(sent.message.title == "Playlist ended")
            #expect(sent.message.body.contains("Road trip"))
            #expect(sent.cover == nil)
        }

        @Test("durations read m:ss, and h:mm:ss from an hour on")
        func durations() {
            #expect(NotificationService.formatDuration(5) == "0:05")
            #expect(NotificationService.formatDuration(185) == "3:05")
            #expect(NotificationService.formatDuration(3723) == "1:02:03")
        }
    }
}
