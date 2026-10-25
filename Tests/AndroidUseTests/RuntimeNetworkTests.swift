import Foundation
import Testing
@testable import AndroidUse

struct RuntimeNetworkTests {
    private func agent(_ id: Int, state: String = "CONNECTED", caps: String = "INTERNET&NOT_RESTRICTED", extra: String = "") -> String {
        "NetworkAgentInfo{network{\(id)} ni{MOBILE[HSPA] \(state) extra: \(extra)} nc{[ Transports: CELLULAR Capabilities: \(caps) ]}}"
    }

    private func ready(_ text: String) -> Bool {
        RuntimeNetworkParser.hasConnectedInternetDefaultNetwork(Data(text.utf8))
    }

    @Test func bootCompletionAloneCannotSupplyAReadyNetwork() {
        #expect(!ready("1"))
        #expect(!ready("Active default network: none\n" + agent(100)))
        #expect(!ready("Active default network: 100\n"))
    }

    @Test func onlyTheCurrentDefaultAgentCanMakeTheNetworkReady() {
        let dump = "Active default network: 100\n" + agent(101) + "\n" + agent(100, state: "DISCONNECTED")
        #expect(!ready(dump))
        #expect(ready("Active default network: 100\n" + agent(101, state: "DISCONNECTED") + "\n" + agent(100)))
    }

    @Test func publicInternetValidationIsNotRequiredForAnEnterpriseNetwork() {
        #expect(ready("Active default network: 100\n" + agent(100)))
        #expect(ready("Active default network: 100\n" + agent(100, caps: "INTERNET&VALIDATED&NOT_RESTRICTED")))
    }

    @Test func unrelatedNamesAndHistoricalFlagsDoNotGrantReadiness() {
        #expect(!ready("Active default network: 100\n" + agent(100, state: "DISCONNECTED", extra: "CONNECTED INTERNET") + "\nOld event: CONNECTED VALIDATED INTERNET"))
        #expect(!ready("Active default network: 100\n" + agent(100, caps: "NOT_RESTRICTED", extra: "INTERNET")))
    }

    @Test func malformedOrTruncatedAgentCannotBecomeReady() {
        let dump = "Active default network: 100\n" + agent(100)
        #expect(!ready(String(dump.dropLast())))
        #expect(!ready(dump.replacingOccurrences(of: "ni{MOBILE[HSPA] CONNECTED", with: "ni{unknown")))
        #expect(!ready("Active default network: 999999999999999999999999\n" + agent(100)))
    }

    @Test func nestedRecordsAndNonAsciiExtraInformationKeepTheDefaultAgentBounded() {
        let connected = agent(100, extra: "合成测试 {nested}")
        #expect(ready("  Active default network: 100\n" + connected))
        #expect(!ready("Active default network: 101\n" + connected + "\n" + agent(101, caps: "NOT_RESTRICTED")))
    }
}
