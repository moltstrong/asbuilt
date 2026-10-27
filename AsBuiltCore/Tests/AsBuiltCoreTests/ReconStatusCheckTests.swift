import Foundation
import Testing
@testable import AsBuiltCore

@Suite("Cloud build: background ready checks + copy")
struct ReconStatusCheckTests {
    @Test func taskDescriptionRoundTrips() {
        let c = ReconStatusCheck(jobID: "job_abc123", title: "Pump\tskid 3", attempt: 7)
        let back = ReconStatusCheck(decoding: c.encoded)
        #expect(back == ReconStatusCheck(jobID: "job_abc123", title: "Pump skid 3", attempt: 7))
        #expect(ReconStatusCheck(decoding: nil) == nil)
        #expect(ReconStatusCheck(decoding: "up_1#3") == nil)  // an upload chunk's key is not a status check
        #expect(ReconStatusCheck(decoding: "recon-status-v1\tx\tjob") == nil)
        #expect(ReconStatusCheck(decoding: "recon-status-v1\t0\tjob_1")?.title == "")
    }

    @Test func decidesFromTheJobAnswer() {
        func job(_ state: String, eta: Int? = nil, error: String? = nil) -> Data {
            var j: [String: Any] = ["jobID": "job_1", "state": state]
            if let eta { j["etaSeconds"] = eta }
            if let error { j["error"] = ["code": "build_failed", "message": error] }
            return try! JSONSerialization.data(withJSONObject: j)
        }
        #expect(ReconStatusCheck.decide(status: 200, body: job("done")) == .ready)
        #expect(ReconStatusCheck.decide(status: 200, body: job("failed", error: "Too few photos overlap.")) == .failed("Too few photos overlap."))
        #expect(ReconStatusCheck.decide(status: 200, body: job("processing", eta: 400)) == .again(420))
        #expect(ReconStatusCheck.decide(status: 200, body: job("processing", eta: 5)) == .again(60))
        #expect(ReconStatusCheck.decide(status: 200, body: job("queued", eta: 9000)) == .again(600))
        #expect(ReconStatusCheck.decide(status: 200, body: job("queued")) == .again(180))
        #expect(ReconStatusCheck.decide(status: 404, body: nil) == .stop)
        #expect(ReconStatusCheck.decide(status: 401, body: nil) == .stop)
        #expect(ReconStatusCheck.decide(status: 0, body: nil) == .again(300))      // offline
        #expect(ReconStatusCheck.decide(status: 502, body: Data("<html>".utf8)) == .again(300))
        #expect(ReconStatusCheck.decide(status: 200, body: Data("<html>".utf8)) == .again(300))
    }

    @Test func userFacingCopySaysCloudNotMac() {
        for phase in [RemoteBuild.Phase.preparing, .uploading, .waitingForMac, .queued, .building, .downloading, .done, .failed, .cancelled] {
            var b = RemoteBuild(photoCount: 40)
            b.phase = phase
            #expect(!b.headline.contains("Mac"), "\(phase): \(b.headline)")
            #expect(!b.detailLine.contains("Mac"), "\(phase): \(b.detailLine)")
        }
        var b = RemoteBuild(photoCount: 40)
        b.phase = .uploading
        #expect(b.headline == "Sending photos to the cloud")
        b.phase = .waitingForMac
        #expect(b.detailLine == "The cloud isn't reachable right now. AsBuilt keeps trying.")
    }
}
