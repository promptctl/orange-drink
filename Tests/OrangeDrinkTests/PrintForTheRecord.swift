/// A line a hardware check prints for the person at it, which `make <check>` also posts on the branch's ticket.
/// [LAW:one-source-of-truth] exception: the mark is said twice, here and as `recordMark` in scripts/hardware-check.swift,
/// which picks these lines out of xcodebuild's output. Change both together.
func printForTheRecord(_ line: String) { print("» \(line)") }
