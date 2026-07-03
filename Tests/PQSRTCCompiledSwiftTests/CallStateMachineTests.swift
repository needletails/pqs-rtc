import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct CallStateMachineTests {
    @Test
    func enumsCodableRoundTrip() throws {
        for callType in [CallStateMachine.CallType.voice, CallStateMachine.CallType.video] {
            let data = try JSONEncoder().encode(callType)
            let decoded = try JSONDecoder().decode(CallStateMachine.CallType.self, from: data)
            #expect(callType == decoded)
        }

        let inbound = CallStateMachine.CallDirection.inbound(.voice)
        let outbound = CallStateMachine.CallDirection.outbound(.video)

        let inboundData = try JSONEncoder().encode(inbound)
        let outboundData = try JSONEncoder().encode(outbound)

        let inboundDecoded = try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: inboundData)
        let outboundDecoded = try JSONDecoder().decode(CallStateMachine.CallDirection.self, from: outboundData)

        #expect(inbound.description == inboundDecoded.description)
        #expect(outbound.description == outboundDecoded.description)

        let canonicalAuxiliaryDeviceAnswered = CallStateMachine.EndState.auxiliaryDeviceAnswered

        let endStates: [CallStateMachine.EndState] = [
            .userInitiated,
            .partnerInitiated,
            .userInitiatedUnanswered,
            .partnerInitiatedUnanswered,
            .partnerInitiatedRejected,
            .failed,
            canonicalAuxiliaryDeviceAnswered
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for endState in endStates {
            let data = try encoder.encode(endState)
            let decoded = try decoder.decode(CallStateMachine.EndState.self, from: data)
            #expect(!String(data: data, encoding: .utf8)!.isEmpty)
            let reencoded = try encoder.encode(decoded)
            #expect(reencoded == data)
        }
    }

    @Test
    func endStateAuxiliaryDeviceAnsweredWireCompatibility() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let canonical = CallStateMachine.EndState.auxiliaryDeviceAnswered
        let legacyWireData = Data(#""auxialaryDevcieAnswered""#.utf8)
        let canonicalWireData = Data(#""auxiliaryDeviceAnswered""#.utf8)

        let encodedCanonical = try encoder.encode(canonical)
        #expect(encodedCanonical == canonicalWireData)

        let decodedLegacy = try decoder.decode(CallStateMachine.EndState.self, from: legacyWireData)
        let reencodedLegacy = try encoder.encode(decodedLegacy)
        #expect(reencodedLegacy == canonicalWireData)

        let decodedCanonical = try decoder.decode(CallStateMachine.EndState.self, from: canonicalWireData)
        let reencodedCanonical = try encoder.encode(decodedCanonical)
        #expect(reencodedCanonical == canonicalWireData)
    }

    @Test
    func stateCodableRoundTrip() throws {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        let states: [CallStateMachine.State] = [
            .waiting,
            .ready(call),
            .connecting(.inbound(.voice), call),
            .connected(.outbound(.video), call),
            .held(nil, call),
            .ended(.userInitiated, call),
            .failed(nil, call, "oops"),
            .callAnsweredAuxDevice(call)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(CallStateMachine.State.self, from: data)
            #expect(state.description == decoded.description)
        }
    }

    @Test
    func transitionSkipsDuplicate() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.transition(to: .ready(call))
        let prev = await sm.currentState

        await sm.transition(to: .ready(call))
        let now = await sm.currentState

        #expect(prev?.description == now?.description)
    }

    // MARK: - App-layer stream tests

    @Test("createStreams should create the app-layer stream")
    func appLayerStreamCreatedWithStreams() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        let streamBefore = await sm.appLayerStream
        #expect(streamBefore == nil)

        await sm.createStreams(with: call)

        let streamAfter = await sm.appLayerStream
        #expect(streamAfter != nil)
    }

    @Test("appLayerStream should receive all state transitions")
    func appLayerStreamReceivesTransitions() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.createStreams(with: call)

        guard let stream = await sm.appLayerStream else {
            Issue.record("appLayerStream should exist after createStreams")
            return
        }

        // Collect states in a task
        let collected = ActorBox<[String]>([])
        let consumeTask = Task {
            for await state in stream {
                await collected.append(state.description)
            }
        }

        // .ready is emitted during createStreams, then add more transitions
        await sm.transition(to: .connecting(.outbound(.voice), call))
        await sm.transition(to: .connected(.outbound(.voice), call))
        await sm.transition(to: .ended(.userInitiated, call))

        // Finish the continuation so the for-await loop ends
        await sm.resetState()

        await consumeTask.value

        let descriptions = await collected.value
        // Should have received: .ready, .connecting, .connected, .ended
        #expect(descriptions.count == 4)
        #expect(descriptions[0].contains("Ready"))
        #expect(descriptions[1].contains("Connecting"))
        #expect(descriptions[2].contains("Connected"))
        #expect(descriptions[3].contains("Ended"))
    }

    @Test("cleanup should finish the app-layer stream")
    func cleanupFinishesAppLayerStream() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.createStreams(with: call)
        #expect(await sm.appLayerStream != nil)

        await sm.resetState()

        #expect(await sm.appLayerStream == nil)
    }

    @Test("appLayerStream uses bufferingOldest so early states are not dropped")
    func appLayerStreamBuffersEarlyStates() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call = try Call(sharedCommunicationId: "comm", sender: sender, recipients: [recipient])

        await sm.createStreams(with: call)

        // Emit several transitions BEFORE anyone starts consuming
        await sm.transition(to: .connecting(.outbound(.voice), call))
        await sm.transition(to: .connected(.outbound(.voice), call))

        guard let stream = await sm.appLayerStream else {
            Issue.record("appLayerStream should exist")
            return
        }

        let collected = ActorBox<[String]>([])
        let consumeTask = Task {
            for await state in stream {
                await collected.append(state.description)
            }
        }

        // Finish the stream so the consumer exits
        await sm.resetState()
        await consumeTask.value

        let descriptions = await collected.value
        // .ready (from createStreams), .connecting, .connected should all be buffered
        #expect(descriptions.count == 3)
        #expect(descriptions[0].contains("Ready"))
        #expect(descriptions[1].contains("Connecting"))
        #expect(descriptions[2].contains("Connected"))
    }

    @Test("createStreams called twice produces fresh working streams")
    func createStreamsReplacesExistingStreams() async throws {
        let sm = CallStateMachine()
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        let call1 = try Call(sharedCommunicationId: "call-1", sender: sender, recipients: [recipient])
        let call2 = try Call(sharedCommunicationId: "call-2", sender: sender, recipients: [recipient])

        await sm.createStreams(with: call1)

        // Simulate end-of-call: transitions fire, then the stream consumers finish
        await sm.transition(to: .connecting(.outbound(.voice), call1))
        await sm.transition(to: .ended(.userInitiated, call1))

        // Second call: createStreams must produce fresh, working streams
        await sm.createStreams(with: call2)

        guard let stream = await sm.appLayerStream else {
            Issue.record("appLayerStream should exist after second createStreams")
            return
        }

        let collected = ActorBox<[String]>([])
        let consumeTask = Task {
            for await state in stream {
                await collected.append(state.description)
            }
        }

        await sm.transition(to: .connecting(.inbound(.video), call2))
        await sm.transition(to: .connected(.inbound(.video), call2))
        await sm.resetState()
        await consumeTask.value

        let descriptions = await collected.value
        #expect(descriptions.count >= 3, "Second call streams should receive .ready, .connecting, .connected but got \(descriptions)")
        #expect(descriptions[0].contains("Ready"))
        #expect(descriptions[1].contains("Connecting"))
        #expect(descriptions[2].contains("Connected"))
    }
}

/// Thread-safe box for collecting values in async test tasks.
private actor ActorBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
extension ActorBox where T == [String] {
    func append(_ element: String) { value.append(element) }
}
