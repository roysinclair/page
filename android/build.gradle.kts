plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

// Dependency locking (SonarCloud text:S8569): every resolvable configuration of every
// module is pinned in its own gradle.lockfile, so a build cannot silently pick up a newer
// transitive version. Refresh after changing a dependency or libs.versions.toml with
//   ./gradlew dependencies --write-locks
// and commit the changed gradle.lockfile files.
allprojects {
    dependencyLocking {
        lockAllConfigurations()
    }
}
