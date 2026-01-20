////
////  XCSkipTests.swift
////  pqs-rtc
////
////  Created by Cole M on 10/4/25.
////
//
//
//import Foundation
//#if os(macOS) // Skip transpiled tests only run on macOS targets
//import SkipTest
//
///// This test case will run the transpiled tests for the Skip module.
//@available(macOS 13, macCatalyst 16, *)
//final class XCSkipTests: XCTestCase, XCGradleHarness {
//    public func testSkipModule() async throws {
//        // This is an integration test that requires Gradle + the Skip toolchain to be available
//        // and correctly configured on the local machine/CI runner.
//        //
//        // Make it opt-in so `swift test` remains reliable in environments that don't have
//        // Android/Gradle configured (or where sandboxing prevents it).
//        guard ProcessInfo.processInfo.environment["RUN_SKIP_TESTS"] == "1" else {
//            throw XCTSkip("Skipping Skip/Gradle integration tests. Set RUN_SKIP_TESTS=1 to enable.")
//        }
//        
//        // Run the transpiled JUnit tests for the current test module.
//        // These tests will be executed locally using Robolectric.
//        // Connected device or emulator tests can be run by setting the
//        // `ANDROID_SERIAL` environment variable to an `adb devices`
//        // ID in the scheme's Run settings.
//        //
//        // Note that it isn't currently possible to filter the tests to run.
//        try await runGradleTests()
//    }
//}
//#endif
//
///// True when running in a transpiled Java runtime environment
//let isJava = ProcessInfo.processInfo.environment["java.io.tmpdir"] != nil
///// True when running within an Android environment (either an emulator or device)
//let isAndroid = isJava && ProcessInfo.processInfo.environment["ANDROID_ROOT"] != nil
///// True is the transpiled code is currently running in the local Robolectric test environment
//let isRobolectric = isJava && !isAndroid
///// True if the system's `Int` type is 32-bit.
//let is32BitInteger = Int64(Int.max) == Int64(Int32.max)
