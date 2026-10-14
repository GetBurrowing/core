import AppIntents
import CoreSpotlight
import UserNotifications
import XCTest

@testable import App

/// Records every donation and deletion instead of calling the system.
final class FakeDonationManager: DonationManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private(set) var donated: [(id: String, intent: any AppIntent)] = []
    private(set) var deleted: [[String]] = []

    func donate(_ intent: any AppIntent) async throws -> String {
        lock.withLock {
            counter += 1
            let id = "donation-\(counter)"
            donated.append((id, intent))
            return id
        }
    }

    func deleteDonations(_ identifiers: [String]) async throws {
        lock.withLock { deleted.append(identifiers) }
    }
}

/// Names every id it is asked for, so each event resolves.
struct FakeDonationResolver: DonationResolving {
    func space(host: String, id: String) async -> SpaceEntity? {
        SpaceEntity(id: EntityRef(host: host, uuid: id).id, name: "general", isDirectMessage: false, pathSegment: id, subtitle: "Space")
    }

    func task(host: String, id: String) async -> TaskEntity? {
        TaskEntity(id: EntityRef(host: host, uuid: id).id, title: "Ship it", subtitle: "Task")
    }

    func meeting(host: String, id: String) async -> MeetingEntity? {
        MeetingEntity(id: EntityRef(host: host, uuid: id).id, name: "Standup", slug: "standup", subtitle: "Meeting")
    }

    func person(host: String, id: String, type: String) async -> DonationPerson? {
        DonationPerson(id: EntityRef(host: host, uuid: id).id, name: type == "agent" ? "Higgins" : "Priya", kind: type)
    }
}

/// Task 01a111bb stage 4: recipients-only donations, per-host forgetting,
/// communication notifications and the per-host index.
final class PersonalContextTests: XCTestCase {
    private let a = "a.example.com"
    private let b = "b.example.com"
    private let space = "5a000000-0000-4000-8000-000000000001"
    private let task = "7a000000-0000-4000-8000-000000000001"
    private let meeting = "3a000000-0000-4000-8000-000000000001"
    private let person = "9e000000-0000-4000-8000-000000000001"
    private let agent = "0a0a0a0a-0000-4000-8000-000000000001"
    private let message = "3e000000-0000-4000-8000-000000000001"
    private var defaultsName = ""

    override func setUp() {
        super.setUp()
        defaultsName = "PersonalContextTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func donations(_ manager: FakeDonationManager, saved: Set<String>? = nil) -> Donations {
        Donations(
            manager: manager, ledger: DonationLedger(defaults: UserDefaults(suiteName: defaultsName)), resolver: FakeDonationResolver(),
            isSaved: { host in saved?.contains(host) ?? true })
    }

    private var everyEvent: [DonationEvent] {
        [
            .messageSent(host: a, spaceID: space, recipients: [DonationRecipient(type: "user", id: person)]),
            .messageSent(host: a, spaceID: space, recipients: []),
            .taskOpened(host: a, taskID: task),
            .meetingJoined(host: a, meetingID: meeting, name: "Standup", slug: "standup"),
            .meetingJoined(host: a, meetingID: meeting, name: nil, slug: nil),
            .spaceOpened(host: a, spaceID: space),
            .askedAgent(host: a, agentID: agent),
        ]
    }

    // MARK: Recipients only

    func testNoEventKindDonatesAValueWithContent() async {
        var donatedKinds = 0
        for event in everyEvent {
            let values = await DonationPolicy.values(for: event, resolver: FakeDonationResolver())
            for intent in values.compactMap({ $0.intent() }) {
                donatedKinds += 1
                XCTAssertEqual(DonationPolicy.contentParameters(of: intent), [], "\(event) donates \(type(of: intent))")
            }
        }
        // Every event but an Ask below iOS 27 donates something.
        XCTAssertGreaterThanOrEqual(donatedKinds, everyEvent.count - 1)
    }

    func testTheContentCheckCatchesEveryContentBearingIntent() {
        let spaceEntity = SpaceEntity(id: "\(a)|\(space)", name: "general", isDirectMessage: false, pathSegment: "g", subtitle: "")
        XCTAssertEqual(DonationPolicy.contentParameters(of: SendMessageIntent(space: spaceEntity, message: "the secret plan")), ["message"])
        let ask = AskAgentIntent()
        XCTAssertEqual(DonationPolicy.contentParameters(of: ask), ["question"])
        XCTAssertEqual(DonationPolicy.contentParameters(of: ShowTasksIntent()), ["intent:ShowTasksIntent"], "not allow-listed")
        if #available(iOS 27, *) {
            var send = DonationIntents.send(to: [DonationPerson(id: "\(a)|\(person)", name: "Priya", kind: "user")])
            XCTAssertEqual(DonationPolicy.contentParameters(of: send), [])
            send.content = AttributedString("the secret plan")
            XCTAssertEqual(DonationPolicy.contentParameters(of: send), ["content"])
        }
    }

    func testAMessageToPeopleIsASendWithNoContentOnIOS27AndTheSpaceBelow() async {
        let event = DonationEvent.messageSent(host: a, spaceID: space, recipients: [DonationRecipient(type: "user", id: person)])
        let intents = await DonationPolicy.values(for: event, resolver: FakeDonationResolver()).compactMap { $0.intent() }
        XCTAssertEqual(intents.count, 1)
        if #available(iOS 27, *) {
            let send = try? XCTUnwrap(intents.first as? MessagesSendIntent)
            XCTAssertNil(send?.content)
            XCTAssertEqual(send?.destination.burrowDestination?.entityID, "\(a)|\(person)")
        } else {
            XCTAssertEqual((intents.first as? OpenSpaceIntent)?.target.id, "\(a)|\(space)")
        }
    }

    func testTheBridgeReadsOnlyAllowListedIds() {
        let payload: [String: Any] = [
            "kind": "message_sent", "space_id": space.uppercased(), "text": "the secret plan", "body": "x",
            "recipient_ids": [["type": "user", "id": person, "name": "Priya"], ["type": "bot", "id": agent], ["type": "agent", "id": "nope"]],
        ]
        XCTAssertEqual(
            DonationEvent.fromBridge(payload, host: a),
            .messageSent(host: a, spaceID: space, recipients: [DonationRecipient(type: "user", id: person)]))
        XCTAssertEqual(DonationEvent.fromBridge(["kind": "approval_acted", "task_id": task, "action": "approve"], host: a), .taskOpened(host: a, taskID: task))
        XCTAssertEqual(DonationEvent.fromBridge(["kind": "task_created", "task_id": task], host: a), .taskOpened(host: a, taskID: task))
        XCTAssertEqual(
            DonationEvent.fromBridge(["kind": "meeting_started", "meeting_id": meeting], host: a),
            .meetingJoined(host: a, meetingID: meeting, name: nil, slug: nil))
        XCTAssertNil(DonationEvent.fromBridge(["kind": "message_sent", "space_id": "general"], host: a))
        XCTAssertNil(DonationEvent.fromBridge(["kind": "message_edited", "space_id": space], host: a))
    }

    /// Main donated every successful intent whole after each run. Now an
    /// intent run donates nothing, except an Ask's agent with no question.
    func testIntentRunsAreNotDonatedWhole() async {
        let manager = FakeDonationManager()
        let donor = donations(manager)
        let spaceEntity = SpaceEntity(id: "\(a)|\(space)", name: "general", isDirectMessage: false, pathSegment: "g", subtitle: "")
        await IntentAppHooks.didSucceed(SendMessageIntent(space: spaceEntity, message: "the secret plan"), donations: donor)?.value
        await IntentAppHooks.didSucceed(OpenSpaceIntent(target: spaceEntity), donations: donor)?.value
        var ask = AskAgentIntent()
        ask.agent = AgentEntity(id: "\(a)|\(agent)", name: "Higgins", subtitle: "Agent")
        ask.question = "what is the secret plan?"
        await IntentAppHooks.didSucceed(ask, donations: donor)?.value

        for (_, intent) in manager.donated {
            XCTAssertEqual(DonationPolicy.contentParameters(of: intent), [], "donated \(type(of: intent))")
            XCTAssertFalse(String(describing: intent).contains("secret"))
        }
        if #available(iOS 27, *) {
            XCTAssertEqual(manager.donated.count, 1, "the Ask's agent only")
            let send = manager.donated.first?.intent as? MessagesSendIntent
            XCTAssertEqual(send?.destination.burrowDestination?.entityID, "\(a)|\(agent)")
        } else {
            XCTAssertEqual(manager.donated.count, 0)
        }
    }

    func testRecordRefusesAContentBearingIntent() async {
        let manager = FakeDonationManager()
        let spaceEntity = SpaceEntity(id: "\(a)|\(space)", name: "general", isDirectMessage: false, pathSegment: "g", subtitle: "")
        await donations(manager).record(SendMessageIntent(space: spaceEntity, message: "the secret plan"), host: a)
        XCTAssertEqual(manager.donated.count, 0)
    }

    // MARK: Forgetting one host

    func testForgetDeletesExactlyThatHostsDonations() async {
        let manager = FakeDonationManager()
        let donor = donations(manager)
        await donor.perform(.taskOpened(host: a, taskID: task))
        await donor.perform(.spaceOpened(host: a, spaceID: space))
        await donor.perform(.taskOpened(host: b, taskID: task))
        let aIDs = donor.ledger.ids(for: a)
        let bIDs = donor.ledger.ids(for: b)
        XCTAssertEqual(aIDs.count, 2)
        XCTAssertEqual(bIDs.count, 1)

        await IntentAppHooks.forget(host: a, donations: donor).value
        XCTAssertEqual(manager.deleted, [aIDs], "exactly host A's donations")
        guard manager.deleted.count == 1 else { return }
        XCTAssertEqual(donor.ledger.ids(for: a), [])
        XCTAssertEqual(donor.ledger.ids(for: b), bIDs, "host B's ledger survives")

        // Host B keeps working, and its first donation is still deletable.
        await donor.perform(.meetingJoined(host: b, meetingID: meeting, name: "Standup", slug: "standup"))
        XCTAssertEqual(donor.ledger.ids(for: b).count, 2)
        await IntentAppHooks.forget(host: b, donations: donor).value
        XCTAssertEqual(manager.deleted.count, 2)
        guard manager.deleted.count == 2 else { return }
        XCTAssertEqual(manager.deleted.last, bIDs + [manager.donated.last!.id])
        XCTAssertTrue(Set(manager.deleted[0]).isDisjoint(with: manager.deleted[1]))
    }

    func testADonationThatLandsAfterItsInstallWasRemovedIsDeleted() async {
        let manager = FakeDonationManager()
        let donor = donations(manager, saved: [b])
        await donor.perform(.taskOpened(host: a, taskID: task))
        XCTAssertEqual(donor.ledger.ids(for: a), [])
        XCTAssertEqual(manager.deleted, [[manager.donated[0].id]])
    }

    func testARepeatedEventIsDonatedOnce() async {
        let manager = FakeDonationManager()
        let donor = donations(manager)
        await donor.donate(.taskOpened(host: a, taskID: task)).value
        await donor.donate(.taskOpened(host: a, taskID: task)).value
        XCTAssertEqual(manager.donated.count, 1)
    }

    // MARK: Communication notifications

    private func chatPayload(host: String) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["title": "Priya in general", "body": "the secret plan"], "mutable-content": 1],
            "kind": "chat_message", "install_host": host, "space_id": space, "message_id": message,
            "author_id": person, "author_type": "user", "author_name": "Priya", "space_name": "general",
        ]
    }

    func testAFullChatPayloadNamesItsOwnInstallsEntities() throws {
        // The selected install is NOT the payload's: ids must use the payload's.
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: chatPayload(host: b)))
        // The app ships no installs, so give the shared store a selection.
        let added = InstallStore.shared.installs.contains { $0.host == a } == false
        InstallStore.shared.add(host: a)
        defer {
            if added {
                let removeHook = InstallStore.didRemove
                InstallStore.didRemove = nil
                InstallStore.shared.remove(host: a)
                InstallStore.didRemove = removeHook
            }
        }
        XCTAssertNotNil(InstallStore.shared.selectedHost, "a selected install exists to be wrongly used")
        XCTAssertNotEqual(InstallStore.shared.selectedHost, b)
        XCTAssertEqual(payload.messageEntityID, "\(b)|\(message)")
        XCTAssertEqual(payload.conversationEntityID, "\(b)|\(space)")

        let intent = CommunicationNotification.sendMessageIntent(payload)
        XCTAssertEqual(intent.sender?.displayName, "Priya")
        XCTAssertEqual(intent.sender?.personHandle?.value, "\(b)|\(person)")
        XCTAssertEqual(intent.conversationIdentifier, "\(b)|\(space)")
        XCTAssertEqual(intent.speakableGroupName?.spokenPhrase, "general")
        XCTAssertNil(intent.content, "no message content in the intent")

        if #available(iOS 27, *) {
            XCTAssertEqual(
                CommunicationNotification.entityIdentifiers(payload),
                [
                    EntityIdentifier(for: MessageEntity.self, identifier: "\(b)|\(message)"),
                    EntityIdentifier(for: ConversationEntity.self, identifier: "\(b)|\(space)"),
                ])
            let content = UNMutableNotificationContent()
            content.title = "Priya in general"
            content.userInfo = chatPayload(host: b)
            let built = CommunicationNotification.build(content)
            let ids = (built as? UNMutableNotificationContent)?.appEntityIdentifiers.map { $0.identifier }
            XCTAssertEqual(ids, ["\(b)|\(message)", "\(b)|\(space)"])
            XCTAssertEqual(built.title, "Priya in general")
        }
    }

    func testADirectMessageHasNoGroupName() throws {
        var info = chatPayload(host: a)
        info["space_name"] = "Priya"
        let payload = try XCTUnwrap(CommunicationPayload(userInfo: info))
        XCTAssertNil(CommunicationNotification.sendMessageIntent(payload).speakableGroupName)
    }

    func testARedactedPayloadPassesThroughUntouched() {
        let content = UNMutableNotificationContent()
        content.title = "New message"
        content.body = ""
        content.userInfo = ["aps": ["alert": ["title": "New message"]], "kind": "chat_message", "install_host": a]
        XCTAssertNil(CommunicationPayload(userInfo: content.userInfo))
        XCTAssertTrue(CommunicationNotification.build(content) === content)

        var foreign = chatPayload(host: a)
        foreign["kind"] = "task_assigned"
        XCTAssertNil(CommunicationPayload(userInfo: foreign), "chat kinds only")
    }

    func testANotificationReplyDonatesTheAuthorNotTheText() {
        let reply = PushPayload(userInfo: chatPayload(host: a)).replyDonation()
        XCTAssertEqual(reply, .messageSent(host: a, spaceID: space, recipients: [DonationRecipient(type: "user", id: person)]))
    }

    // MARK: Index

    @available(iOS 18, *)
    func testIndexItemsCarryTheHostAsDomainIdentifier() {
        let tasks = [
            TaskEntity(id: "\(a)|\(task)", title: "Ship it", subtitle: "Task"),
            TaskEntity(id: "\(a)|\(meeting)", title: "Plan it", subtitle: "Task"),
        ]
        let items = SpotlightIndexer.items(tasks, host: a, expires: nil)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.domainIdentifier), [a, a])
        if #available(iOS 27, *) {
            let people = [MessagePersonEntity(id: "\(b)|\(person)", name: "Priya", kind: "user", subtitle: "")]
            XCTAssertEqual(SpotlightIndexer.items(people, host: b).map(\.domainIdentifier), [b])
        }
    }

    func testSharedEntitiesAreSyncableAndShared() {
        guard #available(iOS 27, *) else { return }
        let task = TaskEntity(id: "\(a)|\(task)", title: "Ship it", subtitle: "Task")
        let person = MessagePersonEntity(id: "\(a)|\(person)", name: "Priya", kind: "user", subtitle: "")
        let conversation = ConversationEntity(id: "\(a)|\(space)", name: "general", org: nil, isDirectMessage: false, pathSegment: "g", install: nil)
        let meeting = MeetingEntity(id: "\(a)|\(meeting)", name: "Standup", slug: "standup", subtitle: "")
        XCTAssertEqual(task.ownership, .shared)
        XCTAssertEqual(person.ownership, .shared)
        XCTAssertEqual(conversation.ownership, .shared)
        XCTAssertEqual(meeting.ownership, .shared)
        let all: [Any] = [task, person, conversation, meeting]
        XCTAssertTrue(all.allSatisfy { $0 is any SyncableEntity && $0 is any IndexedEntity })
    }
}
