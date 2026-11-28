package dev.mpx.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.FileNotFoundException
import java.io.IOException

class SavePlaceTest {
    private fun start(
        destination: String = "gallery",
        kind: String = "photo",
        mime: String = "image/jpeg",
        folder: String? = null,
        createdAtMs: Long? = null,
    ) = SaveStart(
        destination = destination,
        folder = folder,
        name = "a.jpg",
        mime = mime,
        kind = kind,
        createdAtMs = createdAtMs,
        path = "/host/a.jpg",
        bytes = null,
        move = false,
    )

    @Test
    fun theGalleryIsAPendingImagesOrVideoRowFrom29() {
        assertEquals(
            SavePlace.Row(SavePlace.Collection.IMAGES, "Pictures/Album", dateTaken = 5L),
            SavePlace.of(start(folder = "Album", createdAtMs = 5L), sdk = 29),
        )
        assertEquals(
            SavePlace.Row(SavePlace.Collection.VIDEO, "Movies", dateTaken = null),
            SavePlace.of(start(kind = "video", mime = "video/mp4"), sdk = 34),
        )
    }

    @Test
    fun anAnimationGoesByItsMimeType() {
        assertEquals(
            SavePlace.Collection.IMAGES,
            (SavePlace.of(start(kind = "animation", mime = "image/gif"), 30) as SavePlace.Row).collection,
        )
        assertEquals(
            SavePlace.Collection.VIDEO,
            (SavePlace.of(start(kind = "animation", mime = "video/mp4"), 30) as SavePlace.Row).collection,
        )
        assertEquals(
            SavePlace.PublicFile("Movies", null, scan = true),
            SavePlace.of(start(kind = "animation", mime = "video/mp4"), 28),
        )
    }

    @Test
    fun downloadsAreADownloadsRowWithNoDateTaken() {
        assertEquals(
            SavePlace.Row(SavePlace.Collection.DOWNLOADS, "Download/Host", dateTaken = null),
            SavePlace.of(start(destination = "downloads", folder = "Host", createdAtMs = 5L), 29),
        )
    }

    @Test
    fun below29ItIsAFileInThePublicDirectory() {
        assertEquals(
            SavePlace.PublicFile("Pictures", "Album", scan = true),
            SavePlace.of(start(folder = "Album"), 28),
        )
        assertEquals(
            SavePlace.PublicFile("Download", "Host", scan = true),
            SavePlace.of(start(destination = "downloads", folder = "Host"), 24),
        )
    }

    @Test
    fun askIsTheDocumentDialogEverywhere() {
        assertEquals(SavePlace.Document, SavePlace.of(start(destination = "ask"), 24))
        assertEquals(SavePlace.Document, SavePlace.of(start(destination = "ask"), 34))
    }

    @Test
    fun aFolderCannotLeaveItsDirectory() {
        assertEquals("a_b", SafeNames.folder("a/b"))
        assertNull(SafeNames.folder(".."))
        assertNull(SafeNames.folder("  "))
        assertEquals("x_y.jpg", SafeNames.file("x/y.jpg"))
        assertEquals("file", SafeNames.file(".."))
    }

    @Test
    fun aTakenLegacyNameGetsTheFirstFreeNumberUpToTen() {
        assertEquals("a.jpg", LegacyNames.free("a.jpg") { false })
        val taken = setOf("a.jpg", "a(1).jpg", "a(2).jpg")
        assertEquals("a(3).jpg", LegacyNames.free("a.jpg") { it in taken })
        assertEquals("notes(1)", LegacyNames.free("notes") { it == "notes" })
        assertEquals(".hidden(1)", LegacyNames.free(".hidden") { it == ".hidden" })
        assertNull(LegacyNames.free("a.jpg") { true })
    }

    @Test
    fun errorsBecomeShortCodesWithoutTheirMessages() {
        assertEquals("ENOSPC", SaveErrors.codeOf(IOException("write failed: ENOSPC (No space left on device)")))
        assertEquals("ENOSPC", SaveErrors.codeOf(RuntimeException(IOException("No space left on device"))))
        assertEquals("security", SaveErrors.codeOf(SecurityException("/x")))
        assertEquals(
            "mimeRejected",
            SaveErrors.codeOf(IllegalArgumentException("MIME type text/plain cannot be inserted")),
        )
        assertEquals("sourceMissing", SaveErrors.codeOf(SaveError("sourceMissing")))
        assertEquals("failed", SaveErrors.codeOf(IOException("broken pipe")))
        assertEquals("failed", SaveErrors.codeOf(FileNotFoundException("/x")))
    }
}
