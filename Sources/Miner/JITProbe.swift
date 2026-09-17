import Foundation
import Darwin
import CRandomX

/// Pre-flight check for JIT executable memory capability.
///
/// Do NOT test this with mprotect(PROT_READ | PROT_WRITE | PROT_EXEC). On iOS the
/// kernel silently drops VM_PROT_EXECUTE from a writable mapping and still returns
/// success, so that test is a false positive on a device without a debugger. Acting
/// on it makes RandomX compile a program into a page it may not execute, and the
/// first instruction fetch kills the process with EXC_BAD_ACCESS /
/// KERN_PROTECTION_FAILURE, termination namespace CODESIGNING, Invalid Page.
///
/// rx_jit_allowed() checks the flag the kernel actually enforces, CS_DEBUGGED, and
/// then verifies that an RWX mapping keeps its execute bit.
public func isJitAvailable() -> Bool {
    return rx_jit_allowed() == 1
}
