import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api("com.squareup.okhttp3:okhttp:4.12.0")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.1.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

tasks.test {
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = false
    }
}

// Real end-to-end against the Mac server with the Android client code path (no Android runtime needed):
//   RECON_BASE_URL / RECON_API_KEY / RECON_DISCOVERY_URL in the environment (never printed),
//   ./gradlew :core:e2e -Pphotos=<dir of JPEGs> -Pout=<dir>
tasks.register<JavaExec>("e2e") {
    group = "verification"
    description = "Uploads a photo folder to the recon server and downloads model.glb (needs RECON_* env)."
    mainClass.set("com.moltstrong.asbuilt.core.cli.E2eMainKt")
    classpath = sourceSets["main"].runtimeClasspath
    val photos = (project.findProperty("photos") as String?) ?: ""
    val out = (project.findProperty("out") as String?) ?: layout.buildDirectory.dir("e2e").get().asFile.path
    args(photos, out)
}
