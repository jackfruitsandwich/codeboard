import Darwin
import Foundation

enum TerminalResizeSignalRelay {
    static func workItem(for panePID: Int32) -> DispatchWorkItem {
        // Construct this closure outside GhosttyTerminalView's MainActor
        // isolation. Dispatching a MainActor-inherited work item to the
        // utility queue traps under Swift's runtime executor checks.
        DispatchWorkItem {
            notifyDetachedContextSurgeonChildren(of: panePID)
        }
    }

    static func detachedContextSurgeonProcessGroups(
        panePID: Int32,
        processes: [ConversationForkProcess],
        processGroupID: (Int32) -> Int32?
    ) -> Set<Int32> {
        var childrenByParent: [Int32: [ConversationForkProcess]] = [:]
        for process in processes {
            childrenByParent[process.parentPID, default: []].append(process)
        }

        var reachablePIDs: Set<Int32> = [panePID]
        var pendingPIDs = [panePID]
        while let parentPID = pendingPIDs.popLast() {
            for child in childrenByParent[parentPID] ?? [] where reachablePIDs.insert(child.pid).inserted {
                pendingPIDs.append(child.pid)
            }
        }

        var processGroups: Set<Int32> = []
        for wrapper in processes where reachablePIDs.contains(wrapper.pid) && isContextSurgeon(wrapper) {
            let wrapperProcessGroup = processGroupID(wrapper.pid)
            for child in childrenByParent[wrapper.pid] ?? [] {
                guard let childProcessGroup = processGroupID(child.pid),
                      childProcessGroup > 1,
                      childProcessGroup == child.pid,
                      childProcessGroup != wrapperProcessGroup else {
                    continue
                }
                processGroups.insert(childProcessGroup)
            }
        }
        return processGroups
    }

    static func notifyDetachedContextSurgeonChildren(of panePID: Int32) {
        let processes = SystemProcessInspector.descendants(of: panePID)
        let processGroups = detachedContextSurgeonProcessGroups(
            panePID: panePID,
            processes: processes,
            processGroupID: { pid in
                let processGroup = getpgid(pid)
                return processGroup > 0 ? processGroup : nil
            }
        )
        for processGroup in processGroups {
            _ = Darwin.kill(-processGroup, SIGWINCH)
        }
    }

    private static func isContextSurgeon(_ process: ConversationForkProcess) -> Bool {
        process.arguments.contains { argument in
            URL(fileURLWithPath: argument).lastPathComponent == "context-surgeon"
        }
    }
}
