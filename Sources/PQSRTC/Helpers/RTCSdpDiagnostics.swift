import Foundation

#if canImport(WebRTC) && !os(Android)
@preconcurrency import WebRTC
#endif

enum RTCSdpDiagnostics {
    private struct Section {
        var kind: String
        var mid: String?
        var direction: String?
        var msidLines = 0
        var fidGroups = 0
        var ssrcAttributes = 0
        var ssrcCnameAttributes = 0
        var ssrcMsidAttributes = 0

        mutating func observe(_ line: String) {
            if line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst("a=mid:".count))
                return
            }
            switch line {
            case "a=sendrecv":
                direction = "sendrecv"
            case "a=sendonly":
                direction = "sendonly"
            case "a=recvonly":
                direction = "recvonly"
            case "a=inactive":
                direction = "inactive"
            default:
                break
            }
            if line.hasPrefix("a=msid:") {
                msidLines += 1
                return
            }
            if line.hasPrefix("a=ssrc-group:FID") {
                fidGroups += 1
                return
            }
            guard line.hasPrefix("a=ssrc:") else { return }
            ssrcAttributes += 1
            if line.contains(" cname:") {
                ssrcCnameAttributes += 1
            }
            if line.contains(" msid:") {
                ssrcMsidAttributes += 1
            }
        }

        var description: String {
            let midDescription = mid ?? "nil"
            let directionDescription = direction ?? "nil"
            return "\(kind)(mid=\(midDescription),dir=\(directionDescription),msid=\(msidLines),fid=\(fidGroups),ssrc=\(ssrcAttributes),cname=\(ssrcCnameAttributes),ssrcMsid=\(ssrcMsidAttributes))"
        }
    }

    static func summary(_ sdp: String) -> String {
        guard !sdp.isEmpty else { return "sections=[]" }

        let normalized = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var sections: [String] = []
        var current: Section?

        func flushCurrent() {
            guard let section = current else { return }
            sections.append(section.description)
            current = nil
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushCurrent()
                let body = line.dropFirst("m=".count)
                let kind = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? "unknown"
                current = Section(kind: kind)
            }
            current?.observe(line)
        }
        flushCurrent()

        guard !sections.isEmpty else { return "sections=[]" }
        return sections.joined(separator: ";")
    }
}

#if canImport(WebRTC) && !os(Android)
enum RTCPeerConnectionMediaDiagnostics {
    private static func describeTrack(_ track: WebRTC.RTCMediaStreamTrack?) -> String {
        guard let track else { return "nil" }
        return "\(track.kind):\(track.trackId):enabled=\(track.isEnabled):ready=\(track.readyState.rawValue)"
    }

    static func summary(_ peerConnection: WebRTC.RTCPeerConnection) -> String {
        let transceivers = peerConnection.transceivers.enumerated().map { index, transceiver in
            "#\(index)(media=\(transceiver.mediaType),recv=\(describeTrack(transceiver.receiver.track)),send=\(describeTrack(transceiver.sender.track)))"
        }.joined(separator: ";")

        let receivers = peerConnection.receivers.enumerated().map { index, receiver in
            "#\(index)(\(describeTrack(receiver.track)))"
        }.joined(separator: ";")

        let senders = peerConnection.senders.enumerated().map { index, sender in
            "#\(index)(\(describeTrack(sender.track)))"
        }.joined(separator: ";")

        return "transceivers=\(peerConnection.transceivers.count)[\(transceivers)] receivers=\(peerConnection.receivers.count)[\(receivers)] senders=\(peerConnection.senders.count)[\(senders)]"
    }
}
#endif
