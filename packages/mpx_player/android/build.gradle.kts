group = "dev.mpx.player"
version = "0.0.1"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "dev.mpx.player"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // Android API 24 is the set's floor (spec, minimum versions).
        minSdk = 24
    }

    // The JNI shim between the bytes cache's native reader and the player's
    // data source (src/main/cpp).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

dependencies {
    // ExoPlayer and its progressive extractors (MP4, WebM, Matroska).
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    // HLS streams, whose playlists and segments go through the bytes cache
    // (StreamPartDataSource).
    implementation("androidx.media3:media3-exoplayer-hls:1.11.1")
    // The media session that keeps the sound owner playing in the background
    // (MpxPlaybackService; the host declares the service).
    implementation("androidx.media3:media3-session:1.11.1")
    // JVM unit tests (src/test): the load control wrapper's guard.
    testImplementation("junit:junit:4.13.2")
}
