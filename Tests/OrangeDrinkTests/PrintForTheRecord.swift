/// A line of evidence a hardware check prints, which `make <check>` posts on the branch's ticket: what the check itself
/// read or saw, never something for the person at it to check.
/// [LAW:one-source-of-truth] exception: the mark is said twice, here and as `recordMark` in scripts/hardware-check.swift,
/// which picks these lines out of xcodebuild's output. Change both together.
func printForTheRecord(_ line: String) { print("» \(line)") }
